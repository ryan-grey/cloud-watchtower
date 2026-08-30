import Foundation

/// A value that may be present, stale, failing, or never yet loaded — with enough history to
/// render honestly in every one of those states. Nothing here ever substitutes zero for
/// "unknown": that is the single most important property of this app.
struct Loaded<Value> {
    var value: Value?
    var lastSuccess: Date?
    var lastFailure: Date?
    var errorText: String?
    var isRefreshing: Bool = false

    var hasValue: Bool { value != nil }
    /// True when a failure has happened since the last success.
    var isFailing: Bool {
        guard let lastFailure else { return false }
        guard let lastSuccess else { return true }
        return lastFailure > lastSuccess
    }

    mutating func succeeded(_ newValue: Value, at date: Date = Date()) {
        value = newValue
        lastSuccess = date
        errorText = nil
        isRefreshing = false
    }

    mutating func failed(_ error: Error, at date: Date = Date()) {
        lastFailure = date
        errorText = error.localizedDescription
        isRefreshing = false
    }

    func age(asOf now: Date = Date()) -> TimeInterval? {
        lastSuccess.map { now.timeIntervalSince($0) }
    }

    /// Older than this stops counting as evidence of health.
    func isStale(asOf now: Date = Date(), after limit: TimeInterval = Health.staleAfter) -> Bool {
        (age(asOf: now) ?? .greatestFiniteMagnitude) > limit
    }
}

/// Persisted so a restart shows real data with an honest age rather than a blank panel.
/// `isRefreshing` is deliberately not encoded: it describes a live request, and restoring it
/// as true would show a spinner for a request that is not running.
extension Loaded: Codable where Value: Codable {
    private enum CodingKeys: String, CodingKey {
        case value, lastSuccess, lastFailure, errorText
    }
}

extension Loaded: Equatable where Value: Equatable {}

struct AlarmSnapshot: Equatable, Codable {
    var name: String
    var state: String           // OK | ALARM | INSUFFICIENT_DATA
    var stateUpdated: Date?
    var reason: String

    var isAlarming: Bool { state == "ALARM" }
    var isUnknown: Bool { state == "INSUFFICIENT_DATA" }
}

struct BudgetSnapshot: Equatable, Codable {
    var name: String
    var limit: Double
    var actual: Double
    var unit: String
    var lastUpdated: Date?

    var fraction: Double { limit > 0 ? actual / limit : 0 }
    var isOverEightyPercent: Bool { fraction >= 0.8 }
}

// MARK: - Metrics

/// One datapoint. Short names because these are the bulk of the on-disk cache.
struct MetricPoint: Equatable, Codable {
    var t: Date
    var v: Double
}

/// One CloudWatch series, ascending by time.
struct MetricSeries: Equatable, Codable {
    var id: String
    var points: [MetricPoint]
}

/// Raw series, exactly as CloudWatch returned them.
///
/// This used to be `[HourBucket]` with three named CloudFront fields — `requests`,
/// `errorRate4xx`, `errorRate5xx`. That was a *narrowing* applied on top of the generic
/// series map `CloudWatchService` already built internally and then discarded. Keeping the
/// series is strictly less machinery, and it is what lets one card render Lambda durations
/// and another render CloudFront error rates without either knowing about the other.
struct MetricsSnapshot: Equatable, Codable {
    var series: [MetricSeries]
    /// Seconds each bucket covers. Needed to decide window membership — see `points`.
    var period: Int = 3600

    /// Buckets whose coverage overlaps the window.
    ///
    /// CloudWatch timestamps a bucket at its **start** and aligns the bucket grid to the
    /// request's `StartTime`, not to clock hours. Since `StartTime` is derived from "now", the
    /// newest bucket always starts almost exactly one window-length ago — so comparing the
    /// bucket's start against `now - hours` excluded it by the request's own latency, every
    /// single poll. Observed live: buckets ran to 22:46:00Z with `now` at 23:46:01Z, and the
    /// entire "last hour" column rendered `—` because a complete, present bucket missed the
    /// cutoff by one second.
    ///
    /// A bucket starting at `t` covers `t ..< t + period`, so it belongs to the window when
    /// that coverage extends past the cutoff. This also stops the 24-hour figure quietly
    /// using 23 buckets.
    func points(_ id: String, hours: Double, now: Date) -> [MetricPoint] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let coverage = Double(period)
        guard let found = series.first(where: { $0.id == id }) else { return [] }
        return found.points.filter { $0.t.addingTimeInterval(coverage) > cutoff }
    }

    /// Aligns two series by timestamp. Only buckets present in *both* contribute, because a
    /// numerator without its denominator is not a rate.
    private func paired(_ a: String, _ b: String, hours: Double, now: Date) -> [(Double, Double)] {
        let left = points(a, hours: hours, now: now)
        let right = Dictionary(points(b, hours: hours, now: now).map { ($0.t, $0.v) },
                               uniquingKeysWith: { first, _ in first })
        return left.compactMap { point in right[point.t].map { (point.v, $0) } }
    }

    /// The displayed value, or nil when it is genuinely undefined.
    ///
    /// nil is load-bearing: an empty window means "no data", and a zero denominator means the
    /// rate does not exist. Both render as `—`. Substituting 0 for either is the lie this
    /// whole app is built to avoid.
    func value(_ spec: DerivedSpec, hours: Double, now: Date = Date()) -> Double? {
        switch spec.form {
        case .sum(let id):
            let slice = points(id, hours: hours, now: now)
            guard !slice.isEmpty else { return nil }
            return slice.reduce(0) { $0 + $1.v }

        case .latest(let id):
            return points(id, hours: hours, now: now).last?.v

        case .ratio(let numerator, let denominator):
            let pairs = paired(numerator, denominator, hours: hours, now: now)
            guard !pairs.isEmpty else { return nil }
            let bottom = pairs.reduce(0) { $0 + $1.1 }
            guard bottom > 0 else { return nil }     // no traffic ⇒ rate undefined, not zero
            let top = pairs.reduce(0) { $0 + $1.0 }
            return (top / bottom) * 100             // ratios are displayed as percentages

        case .weightedAverage(let rate, let weight):
            let pairs = paired(rate, weight, hours: hours, now: now)
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return nil }
            let weighted = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            return weighted / total
        }
    }
}

struct ServiceCost: Equatable, Codable {
    var name: String
    var amount: Double
}

struct CostBreakdown: Equatable, Codable {
    var periodStart: String
    var periodEnd: String
    var services: [ServiceCost]
    var total: Double
    /// Cost Explorer answers with structurally valid, all-zero data while it is still
    /// backfilling. Distinguishing that from a genuine $0 is the whole point of this pair:
    /// a day with no Groups at all has no data, which is not the same as a day that cost $0.
    var populatedDays: Int
    var totalDays: Int

    var looksUnpopulated: Bool { populatedDays * 2 < totalDays }
}

// MARK: - Cards

/// What one card holds. An enum rather than three optional fields so that a card can never be
/// in the impossible state of holding both an alarm and a budget.
enum CardPayload: Equatable, Codable {
    case alarm(AlarmSnapshot)
    case budget(BudgetSnapshot)
    case metrics(MetricsSnapshot)

    var alarm: AlarmSnapshot?    { if case .alarm(let v) = self { return v }; return nil }
    var budget: BudgetSnapshot?  { if case .budget(let v) = self { return v }; return nil }
    var metrics: MetricsSnapshot? { if case .metrics(let v) = self { return v }; return nil }
}

/// A target plus its independently-degrading state.
///
/// One `Loaded` per card is the whole per-card independence guarantee: a card carries its own
/// value, last-success time and last error, so a failing call can never blank a healthy
/// neighbour. N targets does not weaken this — it just means N of them.
struct TargetCard: Identifiable, Equatable {
    var target: WatchTarget
    var state = Loaded<CardPayload>()
    var id: UUID { target.id }

    /// Rebuilds the card list for an edited configuration, carrying over the live state of
    /// every target that survived.
    ///
    /// Surviving an edit matters: re-fetching everything because one card's name was
    /// corrected would blank the panel, and for metric cards it would cost money to refill.
    static func reconcile(targets: [WatchTarget], keeping existing: [TargetCard]) -> [TargetCard] {
        let previous = Dictionary(existing.map { ($0.id, $0.state) },
                                  uniquingKeysWith: { first, _ in first })
        return targets.map { target in
            var card = TargetCard(target: target)
            if let kept = previous[target.id] { card.state = kept }
            return card
        }
    }
}
