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
}

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

/// One hourly bucket of CloudFront metrics.
struct HourBucket: Equatable, Codable {
    var timestamp: Date
    var requests: Double
    var errorRate4xx: Double?
    var errorRate5xx: Double?
}

struct MetricsSnapshot: Equatable, Codable {
    var buckets: [HourBucket]        // ascending by time

    private func window(hours: Double, now: Date) -> [HourBucket] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return buckets.filter { $0.timestamp >= cutoff }
    }

    func requests(hours: Double, now: Date = Date()) -> Double {
        window(hours: hours, now: now).reduce(0) { $0 + $1.requests }
    }

    /// Request-weighted error rate. Averaging the hourly rates directly would be wrong: this
    /// site's traffic swings between 3 and 400 requests an hour, so an unweighted mean lets a
    /// quiet hour with one 404 dominate a busy hour with none.
    func errorRate(hours: Double, kind: ErrorKind, now: Date = Date()) -> Double? {
        let slice = window(hours: hours, now: now)
        let total = slice.reduce(0) { $0 + $1.requests }
        guard total > 0 else { return nil }   // no traffic ⇒ rate undefined, not zero
        let weighted = slice.reduce(0.0) { sum, bucket in
            let rate = kind == .client ? bucket.errorRate4xx : bucket.errorRate5xx
            return sum + (rate ?? 0) * bucket.requests
        }
        return weighted / total
    }

    enum ErrorKind { case client, server }
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
