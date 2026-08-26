import Foundation

/// `Watchtower --selftest [profile]` — exercises every AWS call the app makes and prints the
/// result, then exits. This is how the networking and signing layer gets verified without
/// having to read a 330pt popover, and it is what the README's verification section runs.
enum SelfTest {

    static func runAndExit(profileOverride: String?, includeCost: Bool) -> Never {
        var config = Configuration.load()
        if let profileOverride { config.profileName = profileOverride }

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
        print("  profile        \(config.profileName)")
        print("  region         \(config.region)")
        print("  distribution   \(config.distributionId)")
        print("  alarm          \(config.alarmName)")
        print("  budget         \(config.budgetName)")
        print("")

        guard config.isConfigured else {
            print("[FAIL] configuration  \(Configuration.notConfiguredMessage)")
            return 1
        }

        let meter = CallMeter(directory: DiskCache.directory)
        await meter.reset()
        let credentials = CredentialProvider()
        let client = AWSClient(profileName: config.profileName,
                               credentials: credentials, meter: meter)

        // 1. Credentials
        do {
            _ = try await credentials.credentials(profile: config.profileName)
            let resolution = await credentials.resolution
            print("[ ok ] credentials    \(resolution?.description ?? config.profileName)"
                  + (resolution?.isAssumedRole == true ? " (assumed role)" : " (static keys)"))
        } catch {
            print("[FAIL] credentials    \(error.localizedDescription)")
            print("\nCannot continue without credentials.")
            return 1
        }

        // 1b. Who are we actually calling as? The profile says role_arn, but that is
        //     configuration, not proof. GetCallerIdentity requires no IAM permission and
        //     returns the identity AWS itself resolved for these credentials, which is the
        //     only way to be sure the role was assumed rather than the source keys inherited.
        do {
            let root = try await client.query(
                service: "sts", host: "sts.amazonaws.com", region: "us-east-1",
                api: "GetCallerIdentity", version: "2011-06-15", params: [:])
            let arn = root.find("Arn")?.trimmed ?? "?"
            let kind = arn.contains(":assumed-role/") ? "assumed role" : "IAM user (inherited)"
            print("[ ok ] GetCallerIdentity \(arn)")
            print("         -> calls below run as: \(kind)")
        } catch {
            print("[FAIL] GetCallerIdentity \(error.localizedDescription)")
            failures += 1
        }

        // 2. DescribeAlarms — free
        let cloudWatch = CloudWatchService(client: client, config: config)
        do {
            let alarm = try await cloudWatch.describeAlarm()
            print("[ ok ] DescribeAlarms \(alarm.name) = \(alarm.state)"
                  + (alarm.stateUpdated.map { " since \(ISO8601DateFormatter().string(from: $0))" } ?? ""))
        } catch {
            print("[FAIL] DescribeAlarms \(error.localizedDescription)" + hint(error, api: "DescribeAlarms", config: config))
            failures += 1
        }

        // 3. DescribeBudget — free
        let budgets = BudgetsService(client: client, config: config)
        do {
            let budget = try await budgets.describeBudget()
            print(String(format: "[ ok ] DescribeBudget %@ = $%.2f of $%.2f (%.0f%%)",
                         budget.name, budget.actual, budget.limit, budget.fraction * 100))
        } catch {
            print("[FAIL] DescribeBudget \(error.localizedDescription)" + hint(error, api: "DescribeBudget", config: config))
            failures += 1
        }

        // 4. GetMetricData — billed, 3 metrics
        do {
            let metrics = try await cloudWatch.getMetricData()
            let rate1h = metrics.errorRate(hours: 1, kind: .server)
            let rate24h = metrics.errorRate(hours: 24, kind: .server)
            print(String(format: "[ ok ] GetMetricData  %d hourly buckets", metrics.buckets.count))
            print(String(format: "         last 1h   %6.0f requests   4xx %@   5xx %@",
                         metrics.requests(hours: 1),
                         pct(metrics.errorRate(hours: 1, kind: .client)), pct(rate1h)))
            print(String(format: "         last 24h  %6.0f requests   4xx %@   5xx %@",
                         metrics.requests(hours: 24),
                         pct(metrics.errorRate(hours: 24, kind: .client)), pct(rate24h)))
        } catch {
            print("[FAIL] GetMetricData  \(error.localizedDescription)")
            failures += 1
        }

        // 5. Cost Explorer costs ~$0.01 per call, so it runs only when asked for explicitly.
        //    A self-test that quietly bills you is the exact thing this project is about.
        if includeCost {
            do {
                let breakdown = try await CostExplorerService(client: client, config: config)
                    .monthToDateByService()
                if breakdown.looksUnpopulated {
                    print("[warn] GetCostAndUsage  only \(breakdown.populatedDays)/\(breakdown.totalDays) days have data — still backfilling, NOT a $0 month")
                } else {
                    print(String(format: "[ ok ] GetCostAndUsage %@ -> %@  $%.4f across %d services",
                                 breakdown.periodStart, breakdown.periodEnd,
                                 breakdown.total, breakdown.services.count))
                }
            } catch {
                print("[FAIL] GetCostAndUsage \(error.localizedDescription)"
                      + hint(error, api: "GetCostAndUsage", config: config))
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

    /// Turns an AccessDenied into the specific policy statement to go fix.
    private static func hint(_ error: Error, api: String, config: Configuration) -> String {
        guard let awsError = error as? AWSError, awsError.isPermissionProblem else { return "" }
        switch api {
        case "DescribeAlarms":
            return "\n         fix: statement AlarmStateReadOnly (cloudwatch:DescribeAlarms)"
        case "GetMetricData":
            return "\n         fix: statement MetricsReadOnly (cloudwatch:GetMetricData)"
        case "DescribeBudget":
            return "\n         fix: statement BudgetReadOnly — its Resource ARN must end in"
                 + "\n              budget/\(config.budgetName). A wrong budget name here denies"
                 + "\n              ONLY this call while everything else keeps working."
        case "GetCostAndUsage":
            return "\n         fix: statement CostExplorerReadOnlyManualOnly (ce:GetCostAndUsage)"
        default:
            return ""
        }
    }

    private static func pct(_ value: Double?) -> String {
        guard let value else { return "   n/a" }
        return String(format: "%5.2f%%", value)
    }
}
