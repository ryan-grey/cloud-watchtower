import Foundation

/// `Watchtower --selftest [profile]` — exercises every AWS call the app makes and prints the
/// result, then exits. This is how the networking and signing layer gets verified without
/// having to read a 330pt popover, and it is what the README's verification section runs.
enum SelfTest {

    static func runAndExit(profileOverride: String?) -> Never {
        var config = Configuration.load()
        if let profileOverride { config.profileName = profileOverride }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            exitCode = await run(config: config)
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func run(config: Configuration) async -> Int32 {
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

        // 2. DescribeAlarms — free
        let cloudWatch = CloudWatchService(client: client, config: config)
        do {
            let alarm = try await cloudWatch.describeAlarm()
            print("[ ok ] DescribeAlarms \(alarm.name) = \(alarm.state)"
                  + (alarm.stateUpdated.map { " since \(ISO8601DateFormatter().string(from: $0))" } ?? ""))
        } catch {
            print("[FAIL] DescribeAlarms \(error.localizedDescription)")
            failures += 1
        }

        // 3. DescribeBudget — free
        let budgets = BudgetsService(client: client, config: config)
        do {
            let budget = try await budgets.describeBudget()
            print(String(format: "[ ok ] DescribeBudget %@ = $%.2f of $%.2f (%.0f%%)",
                         budget.name, budget.actual, budget.limit, budget.fraction * 100))
        } catch {
            print("[FAIL] DescribeBudget \(error.localizedDescription)")
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

        // 5. Cost Explorer is deliberately NOT called here — it costs $0.01 per run and a
        //    self-test that quietly bills you is the exact thing this project is about.
        print("[skip] GetCostAndUsage  billed at ~$0.01/call; run with --cost to include it")

        let tally = await meter.snapshot()
        let spend = await meter.costToDate()
        print("")
        print("calls made      \(tally.calls.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
        print(String(format: "metrics billed  %d", tally.metricsRequested))
        print(String(format: "measured cost   $%.5f", spend))
        return failures == 0 ? 0 : 2
    }

    private static func pct(_ value: Double?) -> String {
        guard let value else { return "   n/a" }
        return String(format: "%5.2f%%", value)
    }
}
