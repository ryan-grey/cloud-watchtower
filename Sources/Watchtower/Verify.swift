import Foundation

/// `Watchtower --verify` — offline checks on the logic that has no business being wrong.
///
/// Not XCTest: that framework ships with Xcode, and this project builds with Command Line
/// Tools only. A flag on the binary keeps the constraint intact and stays runnable in CI,
/// which is the same reasoning that produced `--selftest`. `--selftest` proves the app can
/// talk to AWS; this proves it draws the right conclusions from what AWS says, and it costs
/// nothing because it never opens a socket.
enum Verify {

    private static var failures = 0

    static func runAndExit() -> Never {
        print("Watchtower verify — offline logic checks\n")
        derivations()
        honesty()
        deduplication()
        projection()
        migration()
        healthComposition()
        editing()
        batching()

        print("")
        if failures == 0 {
            print("all checks passed")
            exit(0)
        }
        print("\(failures) check(s) failed")
        exit(2)
    }

    // MARK: Harness

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("[ ok ] \(name)")
        } else {
            print("[FAIL] \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            failures += 1
        }
    }

    private static func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.005) -> Bool {
        guard let a else { return false }
        return abs(a - b) < tolerance
    }

    /// An hour boundary, so buckets land on realistic timestamps.
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Hourly buckets, oldest first, the last one starting at `base`.
    ///
    /// CloudWatch timestamps a bucket at its *start*, so the bucket at `base` covers
    /// `base ..< base+3600` and is the one in progress at `now`.
    private static func series(_ id: String, _ values: [Double]) -> MetricSeries {
        let last = values.count - 1
        let points = values.enumerated().map { index, value in
            MetricPoint(t: base.addingTimeInterval(Double(index - last) * 3600), v: value)
        }
        return MetricSeries(id: id, points: points)
    }

    /// One second after the newest bucket ends.
    ///
    /// This is where the app actually is on every poll, and it is not an edge case: the
    /// request's StartTime is `now - windowHours`, so CloudWatch's bucket grid is anchored to
    /// the request rather than to clock hours, and the newest bucket always ends at "now"
    /// plus however long the call took. Fixtures aligned to clock hours would test a
    /// situation this app never encounters.
    private static var now: Date { base.addingTimeInterval(3601) }

    // MARK: 1. The derivation forms

    private static func derivations() {
        print("derivation forms")

        // CloudFront's shape: a percentage rate reported alongside a request count. Two busy
        // hours with no errors and one near-idle hour with a 100% failure rate.
        //   weighted   = (0*500 + 0*400 + 100*2) / 902 = 0.2217%
        //   unweighted = (0 + 0 + 100) / 3            = 33.33%
        // The README measured this divergence on live data at 56.99% vs 51.22%. The point is
        // not the magnitude, it is that the unweighted figure is not an approximation of the
        // weighted one — it is a different claim.
        let cf = MetricsSnapshot(series: [series("req", [500, 400, 2]),
                                          series("e4xx", [0, 0, 100])])
        let weighted = DerivedSpec(label: "4xx rate", unit: .percent,
                                   form: .weightedAverage(rate: "e4xx", weight: "req"),
                                   warnAbove: nil)
        check("weightedAverage is request-weighted, not a mean of rates",
              near(cf.value(weighted, hours: 24, now: now), 0.2217, 0.001),
              "got \(String(describing: cf.value(weighted, hours: 24, now: now)))")

        let unweightedMean = [0.0, 0, 100].reduce(0, +) / 3
        check("the weighted answer differs materially from the unweighted mean",
              abs((cf.value(weighted, hours: 24, now: now) ?? 0) - unweightedMean) > 30)

        // Lambda's shape: two counts. Σerrors / Σinvocations, as a percentage.
        let lambda = MetricsSnapshot(series: [series("inv", [100, 300]),
                                              series("err", [1, 7])])
        let errorRate = DerivedSpec(label: "Error rate", unit: .percent,
                                    form: .ratio(numerator: "err", denominator: "inv"),
                                    warnAbove: nil)
        check("ratio computes Σn/Σd as a percentage (8/400 = 2%)",
              near(lambda.value(errorRate, hours: 24, now: now), 2.0))

        let sum = DerivedSpec(label: "Invocations", unit: .count,
                              form: .sum("inv"), warnAbove: nil)
        check("sum totals the window", near(lambda.value(sum, hours: 24, now: now), 400))

        // The 1-hour and 24-hour figures come out of the same series, which is why one
        // request covers both windows.
        check("a narrower window slices the same series",
              near(lambda.value(sum, hours: 1, now: now), 300))

        // The regression that made the whole "last hour" column read as em-dashes.
        //
        // CloudWatch aligns its bucket grid to the request's StartTime rather than to clock
        // hours, and StartTime is derived from "now" — so the newest bucket reliably starts
        // one window-length ago, and a `t >= now - 3600` filter drops it by however long the
        // request took. Observed live at 22:46:00Z vs a cutoff of 22:46:01Z.
        let boundary = MetricsSnapshot(series: [series("inv", [7, 11])])
        check("a complete bucket is not dropped by the request's own latency",
              near(boundary.value(sum, hours: 1, now: now), 11),
              "got \(String(describing: boundary.value(sum, hours: 1, now: now)))")
        check("and the bucket before it is still excluded",
              !near(boundary.value(sum, hours: 1, now: now), 18))

        // Membership is by coverage, so a 24-hour window gets 24 buckets rather than 23.
        let day = MetricsSnapshot(series: [series("inv", Array(repeating: 1, count: 25))])
        check("a 24h window covers 24 buckets, not 23",
              near(day.value(sum, hours: 24, now: now), 24),
              "got \(String(describing: day.value(sum, hours: 24, now: now)))")

        let latest = DerivedSpec(label: "Latest", unit: .count,
                                 form: .latest("inv"), warnAbove: nil)
        check("latest takes the most recent point",
              near(lambda.value(latest, hours: 24, now: now), 300))

        // Duration weighted by invocations — the same machinery, a different unit.
        let durations = MetricsSnapshot(series: [series("inv", [1000, 1]),
                                                 series("dur", [10, 5000])])
        let avgDuration = DerivedSpec(label: "Avg duration", unit: .milliseconds,
                                      form: .weightedAverage(rate: "dur", weight: "inv"),
                                      warnAbove: nil)
        check("weightedAverage generalises to durations ((10*1000 + 5000*1)/1001 = 14.99ms)",
              near(durations.value(avgDuration, hours: 24, now: now), 14.985, 0.01))
    }

    // MARK: 2. The honesty properties

    private static func honesty() {
        print("\nhonest degradation")

        let noTraffic = MetricsSnapshot(series: [series("req", [0, 0]),
                                                 series("e4xx", [0, 0])])
        let rate = DerivedSpec(label: "4xx rate", unit: .percent,
                               form: .weightedAverage(rate: "e4xx", weight: "req"),
                               warnAbove: nil)
        check("a zero denominator is undefined, not 0%",
              noTraffic.value(rate, hours: 24, now: now) == nil)
        check("undefined renders as — rather than a number",
              Fmt.metric(noTraffic.value(rate, hours: 24, now: now), unit: .percent) == "—")

        let empty = MetricsSnapshot(series: [series("req", [])])
        let sum = DerivedSpec(label: "Requests", unit: .count, form: .sum("req"), warnAbove: nil)
        check("an empty window is undefined, not 0",
              empty.value(sum, hours: 24, now: now) == nil)

        // A window with datapoints that are genuinely zero is a different fact, and must
        // still read as zero.
        let realZero = MetricsSnapshot(series: [series("req", [0, 0, 0])])
        check("datapoints that really are zero still read as 0",
              near(realZero.value(sum, hours: 24, now: now), 0))

        // A numerator whose bucket has no matching denominator is not a rate.
        let ragged = MetricsSnapshot(series: [
            MetricSeries(id: "inv", points: [MetricPoint(t: base.addingTimeInterval(-3600), v: 10)]),
            MetricSeries(id: "err", points: [MetricPoint(t: base.addingTimeInterval(-7200), v: 5)])
        ])
        let ratio = DerivedSpec(label: "Error rate", unit: .percent,
                                form: .ratio(numerator: "err", denominator: "inv"),
                                warnAbove: nil)
        check("unpaired buckets do not manufacture a rate",
              ragged.value(ratio, hours: 24, now: now) == nil)

        // Loaded's staleness contract, which is what pushes the glyph to cloud.slash.
        var loaded = Loaded<CardPayload>()
        loaded.succeeded(.metrics(empty), at: base.addingTimeInterval(-16 * 60))
        check("a value older than 15 minutes counts as stale",
              loaded.isStale(asOf: base))
        loaded.succeeded(.metrics(empty), at: base.addingTimeInterval(-60))
        check("a fresh value does not", !loaded.isStale(asOf: base))

        var failing = Loaded<CardPayload>()
        failing.succeeded(.metrics(empty), at: base.addingTimeInterval(-300))
        failing.failed(AWSError(code: "AccessDenied", message: "nope"), at: base)
        check("a failed refresh keeps the last known value",
              failing.value != nil && failing.isFailing)
        check("and keeps its age", failing.age(asOf: base).map { $0 >= 300 } ?? false)
    }

    // MARK: 3. Deduplication — the only batching that saves money

    private static func deduplication() {
        print("\ndeduplication")

        let group = RecipeID.lambda.group(dimensions: ["FunctionName": "api"])
        let a = WatchTarget(displayName: "A", profile: "p", region: "us-east-1",
                            kind: .metricGroup(group))
        let b = WatchTarget(displayName: "B", profile: "p", region: "us-east-1",
                            kind: .metricGroup(group))
        let elsewhere = WatchTarget(displayName: "C", profile: "p", region: "eu-west-1",
                                    kind: .metricGroup(group))

        let shared = CostProjection.estimate(targets: [a, b])
        check("two targets on the same metrics are billed once",
              shared.uniqueMetrics == 3, "got \(shared.uniqueMetrics)")
        check("and the duplicates are reported", shared.duplicateMetrics == 3)

        let split = CostProjection.estimate(targets: [a, elsewhere])
        check("the same metric in another region cannot share a request",
              split.uniqueMetrics == 6, "got \(split.uniqueMetrics)")

        // Only series a displayed row reads are requested.
        var padded = group
        padded.series.append(SeriesSpec(id: "unused", metricName: "Throttles", stat: "Sum"))
        check("a series nothing displays is never billed", padded.usedSeries.count == 3)
    }

    // MARK: 4. Cost projection

    private static func projection() {
        print("\ncost projection")

        let cloudFront = WatchTarget(displayName: "site", profile: "p", region: "us-east-1",
                                     kind: .metricGroup(RecipeID.cloudFront.group(
                                        dimensions: ["DistributionId": "E1"])))
        let alarm = WatchTarget(displayName: "alarm", profile: "p", region: "us-east-1",
                                kind: .alarm(name: "a"))
        let budget = WatchTarget(displayName: "budget", profile: "p", region: "us-east-1",
                                 kind: .budget(accountId: "1", name: "b"))

        let p = CostProjection.estimate(targets: [cloudFront, alarm, budget])
        // 3 metrics x (30*24*3600 / 900) polls x $0.01/1000 = 3 x 2880 x 0.00001 = $0.0864
        check("the shipped single-distribution setup projects ~$0.09/mo",
              near(p.monthlyMetricCost, 0.0864, 0.0005),
              String(format: "got $%.4f", p.monthlyMetricCost))
        check("alarms and budgets contribute nothing", p.freeCalls == 2)

        // The README's headline: the naive design cost 170% of the budget it watched. The
        // lever is cadence and series count, not batching.
        let naive = CostProjection.estimate(targets: [cloudFront], metricsInterval: 120)
        check("polling every 2 minutes instead of 15 costs 7.5x more",
              near(naive.monthlyMetricCost / (p.monthlyMetricCost), 7.5, 0.01))
    }

    // MARK: 5. Migration from a 1.x install

    private static func migration() {
        print("\nmigration from the shipped app")

        let suite = "dev.ryangrey.watchtower.verify"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("could open a scratch defaults suite", false); return
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set("123456789012", forKey: "accountId")
        defaults.set("E2EXAMPLE", forKey: "distributionId")
        defaults.set("cloudfront-5xx-error-rate", forKey: "alarmName")
        defaults.set("monthly-budget", forKey: "budgetName")
        defaults.set("watchtower", forKey: "profileName")
        defaults.set("eu-west-2", forKey: "region")

        let migrated = Configuration.load(defaults: defaults)
        check("six scalar keys become three targets", migrated.targets.count == 3,
              "got \(migrated.targets.count)")
        check("the alarm survives",
              migrated.targets.contains { if case .alarm(let n) = $0.kind
                                          { return n == "cloudfront-5xx-error-rate" }; return false })
        check("the budget survives with its account id",
              migrated.targets.contains { if case .budget(let a, let n) = $0.kind
                                          { return a == "123456789012" && n == "monthly-budget" }
                                          return false })
        let cf = migrated.targets.first { $0.metricGroup?.recipe == .cloudFront }
        check("the distribution becomes a CloudFront card",
              cf?.metricGroup?.dimensions["DistributionId"] == "E2EXAMPLE")
        check("with Region=Global, without which the metric silently never reports",
              cf?.metricGroup?.dimensions["Region"] == "Global")
        check("pinned to us-east-1 regardless of the configured region",
              cf?.region == "us-east-1", "got \(cf?.region ?? "nil")")
        check("the configured region still applies to the other cards",
              migrated.targets.first { $0.metricGroup == nil }?.region == "eu-west-2")

        // Re-loading must not migrate a second time and duplicate everything.
        let again = Configuration.load(defaults: defaults)
        check("re-loading does not duplicate the migrated targets", again.targets.count == 3)
        check("and target ids are stable across loads",
              Set(again.targets.map(\.id)) == Set(migrated.targets.map(\.id)))

        // The old keys are left alone, so the shipped app still works if Pro is removed.
        check("legacy keys are not deleted",
              defaults.string(forKey: "distributionId") == "E2EXAMPLE")

        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: 7. Settings-window edits

    private static func editing() {
        print("\nediting a configuration")

        var config = Configuration.empty
        let lambdaID = config.addMetric(.lambda)
        let alarmID = config.addAlarm()
        let budgetID = config.addBudget()
        check("add produces one target per call", config.targets.count == 3)
        check("a new budget inherits the default account id",
              { if case .budget(let account, _) = config.targets[2].kind
                { return account == Configuration.placeholderAccountId }; return false }())
        check("a new CloudFront card is pinned to us-east-1 on creation",
              { var c = Configuration.empty
                let id = c.addMetric(.cloudFront)
                return c.targets.first { $0.id == id }?.region == "us-east-1" }())

        // Re-typing a card keeps its identity, so the panel does not lose its cached value.
        config.changeRecipe(lambdaID, to: .apiGateway)
        check("changing a recipe preserves the target's id",
              config.targets.contains { $0.id == lambdaID })
        check("and swaps in the new recipe's metrics",
              config.targets.first { $0.id == lambdaID }?.metricGroup?.recipe == .apiGateway)

        // A dimension the new recipe does not use must not be carried across.
        var carrying = Configuration.empty
        let cfID = carrying.addMetric(.cloudFront)
        carrying.targets[0].kind = .metricGroup(
            RecipeID.cloudFront.group(dimensions: ["DistributionId": "E1"]))
        carrying.changeRecipe(cfID, to: .lambda)
        check("a dimension the new recipe cannot use is dropped",
              carrying.targets[0].metricGroup?.dimensions["DistributionId"] == nil)
        check("and the fixed Region=Global dimension goes with it",
              carrying.targets[0].metricGroup?.dimensions["Region"] == nil)

        // Removal answers what to select next, which is what stops the editor emptying.
        let next = config.remove(alarmID)
        check("removing selects what slid into its place", next == budgetID,
              "got \(String(describing: next))")
        check("and the target is gone", !config.targets.contains { $0.id == alarmID })
        let last = config.remove(budgetID)
        check("removing the last target selects the one before it", last == lambdaID)
        check("removing everything selects nothing", config.remove(lambdaID) == nil)
        check("and leaves an empty, unconfigured configuration",
              config.targets.isEmpty && !config.isConfigured)

        // Applying an edit must not blank cards that survived it.
        var live = Configuration.empty
        let keptID = live.addMetric(.lambda)
        let droppedID = live.addAlarm()
        var cards = TargetCard.reconcile(targets: live.targets, keeping: [])
        cards[0].state.succeeded(.metrics(MetricsSnapshot(series: [])), at: base)
        cards[1].state.succeeded(.alarm(AlarmSnapshot(name: "a", state: "OK",
                                                      stateUpdated: nil, reason: "")), at: base)
        live.remove(droppedID)
        live.targets[0].displayName = "renamed"
        let after = TargetCard.reconcile(targets: live.targets, keeping: cards)
        check("an edit keeps the surviving card's value", after.count == 1
              && after[0].id == keptID && after[0].state.value != nil)
        check("and its last-success time, so its age stays honest",
              after[0].state.lastSuccess == base)

        // A config file must never be written back over the real install.
        var ephemeral = Configuration.demo
        ephemeral.isEphemeral = true
        let suite = "dev.ryangrey.watchtower.verify.ephemeral"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.removePersistentDomain(forName: suite)
            ephemeral.save(defaults: defaults)
            check("a --config run never writes back to defaults",
                  defaults.data(forKey: "targets") == nil)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    // MARK: 8. Batching boundaries

    private static func batching() {
        print("\nbatching boundaries")

        func alarm(_ name: String, _ profile: String, _ region: String) -> WatchTarget {
            WatchTarget(displayName: name, profile: profile, region: region,
                        kind: .alarm(name: name))
        }
        let targets = [
            alarm("a", "prod", "us-east-1"),
            alarm("b", "prod", "us-east-1"),
            alarm("c", "prod", "eu-west-1"),
            alarm("d", "staging", "us-east-1")
        ]
        let buckets = WatchTarget.grouped(targets)
        check("targets bucket by (profile, region)", buckets.count == 3,
              "got \(buckets.count)")
        check("two alarms in one account and region share a single call",
              buckets.contains { $0.count == 2 })
        check("the same region under another profile does not join them",
              buckets.filter { $0.count == 1 }.count == 2)
        check("grouping loses nothing", buckets.flatMap { $0 }.count == targets.count)
        check("bucket order is stable across calls",
              WatchTarget.grouped(targets).map { $0.map(\.displayName) }
                == buckets.map { $0.map(\.displayName) })
    }

    // MARK: 6. Glyph composition across N cards

    private static func healthComposition() {
        print("\nhealth across N targets")

        func card(_ name: String, _ payload: CardPayload, age: TimeInterval = 30) -> TargetCard {
            let kind: WatchTarget.Kind
            switch payload {
            case .alarm:   kind = .alarm(name: name)
            case .budget:  kind = .budget(accountId: "1", name: name)
            case .metrics: kind = .metricGroup(RecipeID.cloudFront.group(dimensions: [:]))
            }
            var target = TargetCard(target: WatchTarget(displayName: name, profile: "p",
                                                        region: "us-east-1", kind: kind))
            target.state.succeeded(payload, at: base.addingTimeInterval(-age))
            return target
        }

        let ok = AlarmSnapshot(name: "a", state: "OK", stateUpdated: nil, reason: "")
        let firing = AlarmSnapshot(name: "b", state: "ALARM", stateUpdated: nil, reason: "")
        let overspent = BudgetSnapshot(name: "c", limit: 5, actual: 17, unit: "USD",
                                       lastUpdated: nil)
        let fine = BudgetSnapshot(name: "d", limit: 5, actual: 1, unit: "USD", lastUpdated: nil)

        if case .ok = Health.evaluate(cards: [card("a", .alarm(ok)), card("d", .budget(fine))],
                                      now: base) {
            check("all-clear across several cards is ok", true)
        } else {
            check("all-clear across several cards is ok", false)
        }

        // Two live conditions must both be named; one must not mask the other.
        let both = Health.evaluate(cards: [card("b", .alarm(firing)),
                                           card("c", .budget(overspent))], now: base)
        if case .warning(let reasons) = both {
            check("two live conditions are both reported", reasons.count == 2,
                  "got \(reasons)")
            check("and the summary composes them",
                  both.summary.contains("firing") && both.summary.contains("340%"),
                  both.summary)
        } else {
            check("two live conditions are both reported", false)
        }

        // A card that cannot be reached outranks healthy neighbours.
        var broken = card("a", .alarm(ok))
        broken.state = Loaded<CardPayload>()
        broken.state.failed(AWSError(code: "AccessDenied", message: "denied"), at: base)
        if case .unknown = Health.evaluate(cards: [broken, card("d", .budget(fine))], now: base) {
            check("an unreachable card is not averaged away by a healthy one", true)
        } else {
            check("an unreachable card is not averaged away by a healthy one", false)
        }

        // Stale data is not evidence of health.
        if case .unknown = Health.evaluate(cards: [card("a", .alarm(ok), age: 20 * 60)],
                                           now: base) {
            check("a stale value stops counting as evidence of health", true)
        } else {
            check("a stale value stops counting as evidence of health", false)
        }

        // Metric cards are billed and lazy, so they must never vote on the glyph.
        let metricsOnly = Health.evaluate(
            cards: [card("m", .metrics(MetricsSnapshot(series: [])))], now: base)
        if case .unknown(let reason) = metricsOnly {
            check("a metrics-only configuration says the glyph has nothing to judge",
                  reason.contains("no alarm or budget"), reason)
        } else {
            check("a metrics-only configuration says the glyph has nothing to judge", false)
        }

        if case .unknown = Health.evaluate(cards: [], now: base) {
            check("no targets at all is unknown, not ok", true)
        } else {
            check("no targets at all is unknown, not ok", false)
        }
    }
}
