import Foundation

// MARK: - What a metric card asks CloudWatch for

/// One CloudWatch series to request. `id` is local to its group and is what `DerivedSpec`
/// refers to; the wire-level `Id` sent to GetMetricData is assigned at request time, because
/// identical series shared by several targets are fetched once and fanned out.
struct SeriesSpec: Codable, Equatable {
    var id: String
    var metricName: String
    var stat: String
}

/// How a displayed number is computed from the raw series.
///
/// This is deliberately a closed set of four forms, not an expression language. Every one of
/// them has a defined answer to "what does no data mean?", which is the property that lets a
/// generic metric card keep the honesty guarantees the CloudFront-specific one had.
enum DerivedForm: Codable, Equatable {
    /// Total over the window. Undefined — not zero — when the window holds no datapoints.
    case sum(String)
    /// Σnumerator / Σdenominator. Lambda, API Gateway and DynamoDB error rates are this shape.
    case ratio(numerator: String, denominator: String)
    /// Σ(rate × weight) / Σweight. CloudFront reports rates as percentages with a separate
    /// request count, so the honest 24-hour figure has to be request-weighted; the unweighted
    /// mean let a quiet hour with one 404 outweigh a busy hour with none (56.99% vs 51.22%
    /// on live data). Also the right form for "average duration weighted by invocations".
    case weightedAverage(rate: String, weight: String)
    /// Most recent datapoint in the window.
    case latest(String)

    /// Every series id this form reads. Used to prune series nothing displays.
    var seriesIDs: [String] {
        switch self {
        case .sum(let id), .latest(let id): return [id]
        case .ratio(let n, let d): return [n, d]
        case .weightedAverage(let r, let w): return [r, w]
        }
    }
}

enum MetricUnit: String, Codable, Equatable {
    case count, percent, milliseconds, bytes
}

/// One row on a metric card, rendered across the group's windows.
struct DerivedSpec: Codable, Equatable {
    var label: String
    var unit: MetricUnit
    var form: DerivedForm
    /// Highlight this row when it exceeds this value. Purely cosmetic — metrics never feed
    /// the menu-bar glyph, so there is no thresholding semantics to get wrong.
    var warnAbove: Double?
}

/// A metric card: what to fetch, and what to show.
struct MetricGroup: Codable, Equatable {
    var recipe: RecipeID
    var namespace: String
    /// e.g. ["DistributionId": "E123", "Region": "Global"], ["FunctionName": "my-fn"].
    var dimensions: [String: String]
    var series: [SeriesSpec]
    var derived: [DerivedSpec]
    /// Seconds per bucket. 3600 keeps the datapoint count small and matches AWS's retention
    /// for cheap resolutions.
    var period: Int
    /// Hours of history to request. One window yields every figure in `windows`; asking for
    /// two windows separately would double the billable metric count for nothing.
    var windowHours: Double
    /// Which windows to render, in hours.
    var windows: [Double]

    static let defaultWindows: [Double] = [1, 24]

    /// The series actually referenced by a displayed row. Anything else is billed for nothing.
    var usedSeries: [SeriesSpec] {
        let needed = Set(derived.flatMap(\.form.seriesIDs))
        return series.filter { needed.contains($0.id) }
    }
}

// MARK: - Recipes

/// Built-in metric shapes for the services small AWS accounts actually run.
///
/// The market argument for a generic metric model was that most small accounts are Lambda +
/// API Gateway + DynamoDB rather than CloudFront. The reason it does not cost the honesty
/// properties is visible in the table below: every one of these services exposes a ratio
/// metric, so the request-weighted rate generalises rather than being dropped.
enum RecipeID: String, Codable, Equatable, CaseIterable {
    case cloudFront, lambda, apiGateway, dynamoDB, custom

    var displayName: String {
        switch self {
        case .cloudFront: return "CloudFront"
        case .lambda:     return "Lambda"
        case .apiGateway: return "API Gateway"
        case .dynamoDB:   return "DynamoDB"
        case .custom:     return "Custom metric"
        }
    }

    /// Dimension names the user must supply for this recipe.
    var dimensionKeys: [String] {
        switch self {
        case .cloudFront: return ["DistributionId"]
        case .lambda:     return ["FunctionName"]
        case .apiGateway: return ["ApiName"]
        case .dynamoDB:   return ["TableName"]
        case .custom:     return []
        }
    }

    /// Dimensions the recipe pins itself.
    var fixedDimensions: [String: String] {
        switch self {
        // Region=Global is mandatory for CloudFront metrics; without it the metric silently
        // never reports and every value reads as missing.
        case .cloudFront: return ["Region": "Global"]
        default:          return [:]
        }
    }

    /// CloudFront publishes its metrics only into us-east-1 regardless of where the
    /// distribution serves from, so the target's region is not the user's to choose.
    var forcedRegion: String? {
        switch self {
        case .cloudFront: return "us-east-1"
        default:          return nil
        }
    }

    var namespace: String {
        switch self {
        case .cloudFront: return "AWS/CloudFront"
        case .lambda:     return "AWS/Lambda"
        case .apiGateway: return "AWS/ApiGateway"
        case .dynamoDB:   return "AWS/DynamoDB"
        case .custom:     return ""
        }
    }

    /// Deliberately three series each, not everything the service publishes. Every extra
    /// series is billed on every poll for every target, so the default is the smallest set
    /// that answers "is it working and how hard".
    func group(dimensions supplied: [String: String]) -> MetricGroup {
        var dimensions = supplied
        for (key, value) in fixedDimensions { dimensions[key] = value }

        let series: [SeriesSpec]
        let derived: [DerivedSpec]

        switch self {
        case .cloudFront:
            series = [
                SeriesSpec(id: "req",  metricName: "Requests",     stat: "Sum"),
                SeriesSpec(id: "e4xx", metricName: "4xxErrorRate",  stat: "Average"),
                SeriesSpec(id: "e5xx", metricName: "5xxErrorRate",  stat: "Average")
            ]
            derived = [
                DerivedSpec(label: "Requests", unit: .count, form: .sum("req"), warnAbove: nil),
                DerivedSpec(label: "4xx rate", unit: .percent,
                            form: .weightedAverage(rate: "e4xx", weight: "req"), warnAbove: nil),
                DerivedSpec(label: "5xx rate", unit: .percent,
                            form: .weightedAverage(rate: "e5xx", weight: "req"), warnAbove: 1)
            ]

        case .lambda:
            series = [
                SeriesSpec(id: "inv", metricName: "Invocations", stat: "Sum"),
                SeriesSpec(id: "err", metricName: "Errors",      stat: "Sum"),
                SeriesSpec(id: "dur", metricName: "Duration",    stat: "Average")
            ]
            derived = [
                DerivedSpec(label: "Invocations", unit: .count, form: .sum("inv"), warnAbove: nil),
                DerivedSpec(label: "Error rate", unit: .percent,
                            form: .ratio(numerator: "err", denominator: "inv"), warnAbove: 1),
                // Weighted by invocations for the same reason CloudFront's rate is: a mean of
                // hourly averages lets a near-idle hour dominate a busy one.
                DerivedSpec(label: "Avg duration", unit: .milliseconds,
                            form: .weightedAverage(rate: "dur", weight: "inv"), warnAbove: nil)
            ]

        case .apiGateway:
            series = [
                SeriesSpec(id: "count", metricName: "Count",     stat: "Sum"),
                SeriesSpec(id: "e4xx",  metricName: "4XXError",  stat: "Sum"),
                SeriesSpec(id: "e5xx",  metricName: "5XXError",  stat: "Sum")
            ]
            derived = [
                DerivedSpec(label: "Requests", unit: .count, form: .sum("count"), warnAbove: nil),
                DerivedSpec(label: "4xx rate", unit: .percent,
                            form: .ratio(numerator: "e4xx", denominator: "count"), warnAbove: nil),
                DerivedSpec(label: "5xx rate", unit: .percent,
                            form: .ratio(numerator: "e5xx", denominator: "count"), warnAbove: 1)
            ]

        case .dynamoDB:
            series = [
                SeriesSpec(id: "read",  metricName: "ConsumedReadCapacityUnits",  stat: "Sum"),
                SeriesSpec(id: "write", metricName: "ConsumedWriteCapacityUnits", stat: "Sum"),
                SeriesSpec(id: "throt", metricName: "ThrottledRequests",          stat: "Sum")
            ]
            derived = [
                DerivedSpec(label: "Read units",  unit: .count, form: .sum("read"),  warnAbove: nil),
                DerivedSpec(label: "Write units", unit: .count, form: .sum("write"), warnAbove: nil),
                DerivedSpec(label: "Throttled",   unit: .count, form: .sum("throt"), warnAbove: 0)
            ]

        case .custom:
            series = [SeriesSpec(id: "v", metricName: "", stat: "Sum")]
            derived = [DerivedSpec(label: "Value", unit: .count, form: .sum("v"), warnAbove: nil)]
        }

        return MetricGroup(recipe: self, namespace: namespace, dimensions: dimensions,
                           series: series, derived: derived,
                           // 25 hours, not 24: the extra hour guarantees a full 24-hour
                           // window is covered even as the current bucket fills.
                           period: 3600, windowHours: 25,
                           windows: MetricGroup.defaultWindows)
    }
}

// MARK: - Watch targets

/// One card in the panel. Self-contained: profile, region and every identifier it needs, so
/// that watching two accounts at once is a matter of having two targets rather than a mode.
struct WatchTarget: Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var profile: String
    var region: String
    var kind: Kind

    enum Kind: Codable, Equatable {
        case alarm(name: String)
        /// Budgets are account-scoped and the ARN embeds the account id, so it lives here
        /// rather than globally — otherwise a second account's budget could not be watched.
        case budget(accountId: String, name: String)
        case metricGroup(MetricGroup)
    }

    init(id: UUID = UUID(), displayName: String, profile: String, region: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.profile = profile
        self.region = region
        self.kind = kind
    }

    /// Free to poll, and therefore allowed to drive the menu-bar glyph.
    var isFree: Bool {
        switch kind {
        case .alarm, .budget: return true
        case .metricGroup:    return false
        }
    }

    var metricGroup: MetricGroup? {
        if case .metricGroup(let group) = kind { return group }
        return nil
    }

    /// Targets bucketed by the credentials and endpoint they share.
    ///
    /// Everything batchable can only be batched inside one of these buckets: a request is
    /// signed for one profile and addressed to one region, so two accounts are always two
    /// calls however similar their metrics look.
    static func grouped(_ targets: [WatchTarget]) -> [[WatchTarget]] {
        Dictionary(grouping: targets) { "\($0.profile)|\($0.region)" }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    var sectionTitle: String {
        switch kind {
        case .alarm:                return "Alarm"
        case .budget:               return "Budget"
        case .metricGroup(let g):   return g.recipe.displayName
        }
    }
}
