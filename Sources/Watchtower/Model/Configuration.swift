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

    /// A configuration exercising every recipe across two profiles and two regions, with no
    /// real identifiers in it. Emitted by `--write-demo-config` and consumed by `--config`.
    static var demo: Configuration {
        func metric(_ name: String, _ recipe: RecipeID, _ dimensions: [String: String],
                    profile: String = "watchtower", region: String = "us-east-1") -> WatchTarget {
            WatchTarget(displayName: name, profile: profile,
                        region: recipe.forcedRegion ?? region,
                        kind: .metricGroup(recipe.group(dimensions: dimensions)))
        }
        return Configuration(
            targets: [
                metric("checkout-api", .lambda, ["FunctionName": "checkout-api"]),
                metric("public-site", .cloudFront, ["DistributionId": "EDEMODIST00001"]),
                metric("orders-api", .apiGateway, ["ApiName": "orders"],
                       profile: "staging", region: "eu-west-1"),
                metric("sessions", .dynamoDB, ["TableName": "sessions"],
                       profile: "staging", region: "eu-west-1"),
                WatchTarget(displayName: "5xx error rate", profile: "watchtower",
                            region: "us-east-1", kind: .alarm(name: "site-5xx-error-rate")),
                WatchTarget(displayName: "lambda errors", profile: "staging",
                            region: "eu-west-1", kind: .alarm(name: "checkout-errors")),
                WatchTarget(displayName: "monthly", profile: "watchtower", region: "us-east-1",
                            kind: .budget(accountId: placeholderAccountId, name: "monthly")),
                WatchTarget(displayName: "staging monthly", profile: "staging",
                            region: "eu-west-1",
                            kind: .budget(accountId: placeholderAccountId,
                                          name: "staging-monthly"))
            ],
            defaultProfile: "watchtower",
            defaultRegion: "us-east-1",
            defaultAccountId: placeholderAccountId)
    }

    /// False until there is at least one target to watch.
    var isConfigured: Bool { !targets.isEmpty }

    static let notConfiguredMessage =
        "Not configured — add a watch target in Settings"

    /// True when this came from `--config`, in which case it must never be written back to
    /// `defaults` — a screenshot run would otherwise overwrite the real install. Not part of
    /// the file format: it describes how a configuration was loaded, not what it contains.
    var isEphemeral = false

    private enum CodingKeys: String, CodingKey {
        case targets, defaultProfile, defaultRegion, defaultAccountId
    }

    // MARK: Editing
    //
    // These are pure mutations on the model rather than methods on the settings window, so
    // that adding, removing and re-typing a target can be checked by `--verify` without
    // constructing an AppState — which would start pollers and open sockets.

    @discardableResult
    mutating func addMetric(_ recipe: RecipeID) -> UUID {
        let target = WatchTarget(displayName: "New \(recipe.displayName)",
                                 profile: defaultProfile,
                                 region: recipe.forcedRegion ?? defaultRegion,
                                 kind: .metricGroup(recipe.group(dimensions: [:])))
        targets.append(target)
        return target.id
    }

    @discardableResult
    mutating func addAlarm() -> UUID {
        let target = WatchTarget(displayName: "New alarm", profile: defaultProfile,
                                 region: defaultRegion, kind: .alarm(name: ""))
        targets.append(target)
        return target.id
    }

    @discardableResult
    mutating func addBudget() -> UUID {
        let target = WatchTarget(displayName: "New budget", profile: defaultProfile,
                                 region: defaultRegion,
                                 kind: .budget(accountId: defaultAccountId, name: ""))
        targets.append(target)
        return target.id
    }

    /// Removes a target and answers what should be selected next — the one that slid into its
    /// place, or the last remaining, or nothing.
    @discardableResult
    mutating func remove(_ id: UUID) -> UUID? {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return nil }
        targets.remove(at: index)
        if targets.indices.contains(index) { return targets[index].id }
        return targets.last?.id
    }

    /// Swapping a recipe keeps whatever dimension values still apply, so moving between two
    /// recipes that share a dimension name does not make the user retype it. The target's id
    /// is preserved, so its card keeps its place and its cached value.
    mutating func changeRecipe(_ id: UUID, to recipe: RecipeID) {
        guard let index = targets.firstIndex(where: { $0.id == id }),
              let existing = targets[index].metricGroup else { return }
        let carried = existing.dimensions.filter { recipe.dimensionKeys.contains($0.key) }
        targets[index].kind = .metricGroup(recipe.group(dimensions: carried))
        if let forced = recipe.forcedRegion { targets[index].region = forced }
    }

    // MARK: Persistence

    private static let targetsKey = "targets"

    /// `--config <path>` runs against a JSON file instead of `defaults`.
    ///
    /// Not only a test hook: CI screenshot generation needs a configuration that is stable
    /// and contains no real account identifiers, and a support request is far easier to
    /// reproduce from a file than from a description of someone's `defaults`.
    static func configPathArgument(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "--config"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func load(defaults d: UserDefaults = .standard) -> Configuration {
        if let path = configPathArgument() {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var loaded = try? JSONDecoder().decode(Configuration.self, from: data) else {
                FileHandle.standardError.write(
                    Data("--config: could not read a configuration from \(path)\n".utf8))
                exit(1)
            }
            loaded.isEphemeral = true
            return loaded
        }
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
        guard !isEphemeral else { return }
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
