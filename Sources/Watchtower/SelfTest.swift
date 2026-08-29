import Foundation

/// `Watchtower --selftest [--profile NAME] [--cost]` — exercises every AWS call the app makes
/// and prints the result, then exits. This is how the networking and signing layer gets
/// verified without having to read a popover, and it is what the README's verification
/// section runs.
///
/// With N targets it walks every one of them, because "the app works" is no longer a single
/// answer: a configuration can be healthy in one account and denied in another, and the whole
/// point of per-card degradation is that those are separate facts.
enum SelfTest {

    static func runAndExit(profileOverride: String?, includeCost: Bool) -> Never {
        var config = Configuration.load()
        if let profileOverride {
            config.defaultProfile = profileOverride
            config.targets = config.targets.map {
                var target = $0
                target.profile = profileOverride
                return target
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            exitCode = await run(config: config, includeCost: includeCost)
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func run(config: Configuration, includeCost: Bool) async -> Int32 {
        var failures = 0
        print("Watchtower self-test")
        print("  profile        \(config.defaultProfile)")
        print("  region         \(config.defaultRegion)")
        print("  targets        \(config.targets.count)")
        for target in config.targets {
            print("    · \(label(target))")
        }
        print("")

        guard config.isConfigured else {
            print("[FAIL] configuration  \(Configuration.notConfiguredMessage)")
            return 1
        }

        let projection = CostProjection.estimate(targets: config.targets)
        print(String(format: "projected cost  $%.2f/mo — %d billed metrics, %d free cards",
                     projection.monthlyMetricCost, projection.uniqueMetrics,
                     projection.freeCalls))
        if projection.duplicateMetrics > 0 {
            print("                \(projection.duplicateMetrics) duplicate metric(s) shared, not double-billed")
        }
        print("")

        let meter = CallMeter(directory: DiskCache.directory)
        await meter.reset()
        let credentials = CredentialProvider()
        let client = AWSClient(profileName: config.defaultProfile,
                               credentials: credentials, meter: meter)

        // 1. Credentials — once per distinct profile in use.
        let profiles = Set(config.targets.map(\.profile)).union([config.defaultProfile])
        for profile in profiles.sorted() {
            do {
                _ = try await credentials.credentials(profile: profile)
                let resolution = await credentials.resolution(for: profile)
                print("[ ok ] credentials    \(resolution?.description ?? profile)"
                      + (resolution?.isAssumedRole == true ? " (assumed role)" : " (static keys)"))
            } catch {
                print("[FAIL] credentials    \(profile): \(error.localizedDescription)")
                failures += 1
            }
        }
        guard failures == 0 else {
            print("\nCannot continue without credentials.")
            return 1
        }

        // 1b. Who are we actually calling as? The profile says role_arn, but that is
        //     configuration, not proof. GetCallerIdentity requires no IAM permission and
        //     returns the identity AWS itself resolved for these credentials, which is the
        //     only way to be sure the role was assumed rather than the source keys inherited.
        for profile in profiles.sorted() {
            do {
                let root = try await client.query(
                    service: "sts", host: "sts.amazonaws.com", region: "us-east-1",
                    profile: profile,
                    api: "GetCallerIdentity", version: "2011-06-15", params: [:])
                let arn = root.find("Arn")?.trimmed ?? "?"
                let kind = arn.contains(":assumed-role/") ? "assumed role" : "IAM user (inherited)"
                print("[ ok ] GetCallerIdentity \(arn)")
                print("         -> \(profile)'s calls run as: \(kind)")
            } catch {
                print("[FAIL] GetCallerIdentity \(profile): \(error.localizedDescription)")
                failures += 1
            }
        }

        let cloudWatch = CloudWatchService(client: client)
        let budgets = BudgetsService(client: client)

        // 2. Every target, in the same batched shape the poller uses.
        for target in config.targets {
            switch target.kind {
            case .alarm(let name):
                do {
                    let found = try await cloudWatch.describeAlarms(
                        names: [name], region: target.region, profile: target.profile)
                    if let alarm = found[name] {
                        print("[ ok ] DescribeAlarms \(alarm.name) = \(alarm.state)"
                              + (alarm.stateUpdated.map {
                                  " since \(ISO8601DateFormatter().string(from: $0))" } ?? ""))
                    } else {
                        print("[FAIL] DescribeAlarms no alarm named “\(name)” in \(target.region)")
                        failures += 1
                    }
                } catch {
                    print("[FAIL] DescribeAlarms \(error.localizedDescription)"
                          + hint(error, api: "DescribeAlarms", target: target))
                    failures += 1
                }

            case .budget(let accountId, let name):
                do {
                    let budget = try await budgets.describeBudget(
                        accountId: accountId, name: name, profile: target.profile)
                    print(String(format: "[ ok ] DescribeBudget %@ = $%.2f of $%.2f (%.0f%%)",
                                 budget.name, budget.actual, budget.limit,
                                 budget.fraction * 100))
                } catch {
                    print("[FAIL] DescribeBudget \(error.localizedDescription)"
                          + hint(error, api: "DescribeBudget", target: target))
                    failures += 1
                }

            case .metricGroup(let group):
                do {
                    let snapshots = try await cloudWatch.fetchMetrics(
                        targets: [target], region: target.region, profile: target.profile)
                    guard let snapshot = snapshots[target.id] else {
                        print("[FAIL] GetMetricData  \(target.displayName): no result")
                        failures += 1
                        continue
                    }
                    let points = snapshot.series.reduce(0) { $0 + $1.points.count }
                    print("[ ok ] GetMetricData  \(target.displayName) "
                          + "(\(group.recipe.displayName)) — \(points) datapoints, "
                          + "\(group.usedSeries.count) metrics billed")
                    // Which buckets actually came back. A window that looks empty is usually
                    // publication lag rather than a broken query, and the two are impossible
                    // to tell apart from the rendered values alone.
                    let stamps = snapshot.series.flatMap { $0.points.map(\.t) }
                    if let newest = stamps.max(), let oldest = stamps.min() {
                        let formatter = ISO8601DateFormatter()
                        let lag = Date().timeIntervalSince(newest) / 60
                        print(String(format: "         buckets   %@ -> %@ (newest is %.0f min old)",
                                     formatter.string(from: oldest),
                                     formatter.string(from: newest), lag))
                    }
                    for spec in group.derived {
                        let cells = group.windows.map { hours in
                            String(format: "%@ %@", Fmt.windowLabel(hours),
                                   Fmt.metric(snapshot.value(spec, hours: hours), unit: spec.unit))
                        }
                        print("         \(spec.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                              + cells.joined(separator: "   "))
                    }
                } catch {
                    print("[FAIL] GetMetricData  \(error.localizedDescription)"
                          + hint(error, api: "GetMetricData", target: target))
                    failures += 1
                }
            }
        }

        // 3. Cost Explorer costs ~$0.01 per call, so it runs only when asked for explicitly.
        //    A self-test that quietly bills you is the exact thing this project is about.
        if includeCost {
            do {
                let breakdown = try await CostExplorerService(client: client)
                    .monthToDateByService(profile: config.defaultProfile)
                if breakdown.looksUnpopulated {
                    print("[warn] GetCostAndUsage  only \(breakdown.populatedDays)/\(breakdown.totalDays) days have data — still backfilling, NOT a $0 month")
                } else {
                    print(String(format: "[ ok ] GetCostAndUsage %@ -> %@  $%.4f across %d services",
                                 breakdown.periodStart, breakdown.periodEnd,
                                 breakdown.total, breakdown.services.count))
                }
            } catch {
                print("[FAIL] GetCostAndUsage \(error.localizedDescription)")
                failures += 1
            }
        } else {
            print("[skip] GetCostAndUsage  billed at ~$0.01/call; pass --cost to include it")
        }

        let tally = await meter.snapshot()
        let spend = await meter.costToDate()
        print("")
        print("calls made      \(tally.calls.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
        print(String(format: "metrics billed  %d", tally.metricsRequested))
        print(String(format: "measured cost   $%.5f", spend))
        return failures == 0 ? 0 : 2
    }

    private static func label(_ target: WatchTarget) -> String {
        let detail: String
        switch target.kind {
        case .alarm(let name):              detail = "alarm \(name)"
        case .budget(let account, let name): detail = "budget \(name) in \(account)"
        case .metricGroup(let group):
            let dims = group.dimensions.keys.sorted()
                .map { "\($0)=\(group.dimensions[$0]!)" }.joined(separator: ",")
            detail = "\(group.recipe.displayName) \(dims)"
        }
        return "\(target.displayName) — \(detail) [\(target.profile)/\(target.region)]"
    }

    /// Turns an AccessDenied into the specific policy statement to go fix.
    private static func hint(_ error: Error, api: String, target: WatchTarget) -> String {
        guard let awsError = error as? AWSError, awsError.isPermissionProblem else { return "" }
        switch api {
        case "DescribeAlarms":
            return "\n         fix: statement AlarmStateReadOnly (cloudwatch:DescribeAlarms)"
        case "GetMetricData":
            return "\n         fix: statement MetricsReadOnly (cloudwatch:GetMetricData)"
        case "DescribeBudget":
            guard case .budget(let account, let name) = target.kind else { return "" }
            return "\n         fix: statement BudgetReadOnly — its Resource ARN must be"
                 + "\n              arn:aws:budgets::\(account):budget/\(name). A wrong budget"
                 + "\n              name here denies ONLY this call while everything else works."
        default:
            return ""
        }
    }
}
