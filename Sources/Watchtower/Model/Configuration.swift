import Foundation

/// What Watchtower watches.
///
/// Pro replaces the six scalar `defaults` keys with a list of watch targets stored as JSON
/// under a single `targets` key. The scalars are still read once, to migrate an existing
/// install — see `migratedFromLegacyKeys`.
///
/// Identifiers are still not committed to the repo. An account id plus an IAM user name is
/// enough for a stranger to construct valid ARNs for your account, which is where targeted
/// enumeration and credible phishing start.
struct Configuration: Codable, Equatable {
    var targets: [WatchTarget]
    /// Used for new targets, for the Cost Explorer button, and for the panel footer.
    var defaultProfile: String
    var defaultRegion: String
    var defaultAccountId: String

    static let placeholderAccountId = "000000000000"
    static let placeholderDistributionId = "EXAMPLEDISTID0"

    static let empty = Configuration(targets: [],
                                     defaultProfile: "watchtower",
                                     defaultRegion: "us-east-1",
                                     defaultAccountId: placeholderAccountId)

    /// False until there is at least one target to watch.
    var isConfigured: Bool { !targets.isEmpty }

    static let notConfiguredMessage =
        "Not configured — add a watch target in Settings"

    // MARK: Persistence

    private static let targetsKey = "targets"

    static func load(defaults d: UserDefaults = .standard) -> Configuration {
        var config = Configuration.empty
        if let v = d.string(forKey: "profileName"), !v.isEmpty { config.defaultProfile = v }
        if let v = d.string(forKey: "region"), !v.isEmpty { config.defaultRegion = v }
        if let v = d.string(forKey: "accountId"), !v.isEmpty { config.defaultAccountId = v }

        if let data = d.data(forKey: targetsKey),
           let saved = try? JSONDecoder().decode([WatchTarget].self, from: data) {
            config.targets = saved
            return config
        }

        // No structured config yet: this is either a fresh install or a 1.x install being
        // upgraded. Both are handled by reading the old scalar keys.
        config.targets = migratedFromLegacyKeys(defaults: d, config: config)
        if !config.targets.isEmpty { config.save(defaults: d) }
        return config
    }

    func save(defaults d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(targets) {
            d.set(data, forKey: Configuration.targetsKey)
        }
        d.set(defaultProfile, forKey: "profileName")
        d.set(defaultRegion, forKey: "region")
        d.set(defaultAccountId, forKey: "accountId")
    }

    /// Turns a 1.x install into three targets so the author's own setup survives the upgrade.
    ///
    /// Deliberately non-destructive: the old keys are read, never deleted. If Pro is
    /// uninstalled the shipped app still finds its configuration exactly where it left it.
    static func migratedFromLegacyKeys(defaults d: UserDefaults,
                                       config: Configuration) -> [WatchTarget] {
        let accountId = d.string(forKey: "accountId") ?? ""
        let distributionId = d.string(forKey: "distributionId") ?? ""
        let alarmName = d.string(forKey: "alarmName") ?? ""
        let budgetName = d.string(forKey: "budgetName") ?? ""
        let profile = config.defaultProfile
        let region = config.defaultRegion

        var targets: [WatchTarget] = []

        if !alarmName.isEmpty {
            targets.append(WatchTarget(displayName: alarmName, profile: profile,
                                       region: region, kind: .alarm(name: alarmName)))
        }
        if !distributionId.isEmpty, distributionId != placeholderDistributionId {
            let group = RecipeID.cloudFront.group(
                dimensions: ["DistributionId": distributionId])
            targets.append(WatchTarget(displayName: distributionId, profile: profile,
                                       // CloudFront metrics live only in us-east-1.
                                       region: RecipeID.cloudFront.forcedRegion ?? region,
                                       kind: .metricGroup(group)))
        }
        if !budgetName.isEmpty, !accountId.isEmpty, accountId != placeholderAccountId {
            targets.append(WatchTarget(displayName: budgetName, profile: profile,
                                       region: region,
                                       kind: .budget(accountId: accountId, name: budgetName)))
        }
        return targets
    }
}

// MARK: - Cost projection

/// What a given configuration costs to watch, per month, before the user commits to it.
///
/// The product thesis is that monitoring should not cost a meaningful fraction of the thing
/// it monitors. With one hardcoded distribution that could be a README table. With N targets
/// the user builds the bill themselves, so the bill has to be visible while they build it.
///
/// The billed unit is **metrics requested**, not requests: GetMetricData is $0.01 per 1,000
/// metrics, so splitting three metrics across three calls costs exactly what one call with
/// three metrics costs. Batching buys throttling headroom and latency, not money. The levers
/// that actually move this number are the count of distinct series and the poll interval.
struct CostProjection {
    var uniqueMetrics: Int
    var duplicateMetrics: Int
    var freeCalls: Int
    var pollsPerMonth: Double
    var monthlyMetricCost: Double

    static let secondsPerMonth: Double = 30 * 24 * 3600

    /// The sentence under the headline figure. Built here rather than in the view because a
    /// concatenation this long makes SwiftUI's type-checker give up.
    var summary: String {
        let polls = Int(pollsPerMonth.rounded())
        let cards = freeCalls == 1 ? "card" : "cards"
        return "\(uniqueMetrics) billed metrics x \(polls) polls/mo at idle cadence. "
             + "\(freeCalls) alarm/budget \(cards) cost nothing."
    }

    var duplicateNote: String? {
        guard duplicateMetrics > 0 else { return nil }
        let plural = duplicateMetrics == 1 ? "metric is" : "metrics are"
        return "\(duplicateMetrics) duplicate \(plural) fetched once and shared across "
             + "targets, so you are not billed twice."
    }

    /// Idle cadence is the honest baseline: it is what the app does when nobody is looking,
    /// which is almost all of the time.
    static func estimate(targets: [WatchTarget],
                         metricsInterval: TimeInterval = PollingIntervals.metricsIdle) -> CostProjection {
        let groups = targets.compactMap(\.metricGroup)
        let requested = groups.reduce(0) { $0 + $1.usedSeries.count }
        let unique = Set(targets.flatMap { target -> [String] in
            guard let group = target.metricGroup else { return [] }
            return group.usedSeries.map {
                MetricQuery(group: group, series: $0, region: target.region,
                            profile: target.profile).canonicalKey
            }
        }).count

        let polls = secondsPerMonth / max(metricsInterval, 1)
        let cost = Double(unique) * polls * CallMeter.Price.perGetMetricDataMetric
        return CostProjection(uniqueMetrics: unique,
                              duplicateMetrics: max(0, requested - unique),
                              freeCalls: targets.filter(\.isFree).count,
                              pollsPerMonth: polls,
                              monthlyMetricCost: cost)
    }
}

/// Poll cadences, outside the main actor so cost projection can be computed anywhere.
enum PollingIntervals {
    /// Free (DescribeAlarms). Drives the glyph, so it runs fastest.
    static let alarm: TimeInterval = 60
    /// Free (DescribeBudget). AWS recalculates spend ~3x/day; 10 minutes is already generous.
    static let budget: TimeInterval = 600
    /// Billed. 5 minutes while the panel is in use...
    static let metricsActive: TimeInterval = 300
    /// ...15 minutes otherwise. The glyph never depends on this, so it can afford to be slow.
    static let metricsIdle: TimeInterval = 900
    /// A panel reopened within a minute reuses what is on screen rather than paying again.
    static let metricsOpenThrottle: TimeInterval = 60
    /// How long after the panel closes we keep treating the app as "in use".
    static let activeWindow: TimeInterval = 600
}

enum AWSDate {
    /// AWS mixes fractional-second and whole-second ISO 8601. Try both.
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
