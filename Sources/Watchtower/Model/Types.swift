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

/// One service's month-to-date estimated charge, as CloudWatch publishes it.
struct BillingCharge: Equatable, Codable {
    var service: String
    var amount: Double

    /// CloudWatch's ServiceName dimension uses billing codes, not the display names Cost
    /// Explorer returns. Left as-is when unrecognised so a new service still renders.
    var displayName: String {
        switch service {
        case "AmazonS3":            return "S3"
        case "AmazonEC2":           return "EC2"
        case "AmazonCloudFront":    return "CloudFront"
        case "AmazonRoute53":       return "Route 53"
        case "AmazonDynamoDB":      return "DynamoDB"
        case "AmazonSES":           return "SES"
        case "AmazonSNS":           return "SNS"
        case "AmazonBedrock":       return "Bedrock"
        case "AmazonCognito":       return "Cognito"
        case "AmazonApiGateway":    return "API Gateway"
        case "AmazonCloudWatch":    return "CloudWatch"
        case "AWSQueueService":     return "SQS"
        case "AWSDataTransfer":     return "Data transfer"
        case "AWSLambda":           return "Lambda"
        case "AWSGlue":             return "Glue"
        case "AWSEvents":           return "EventBridge"
        case "AWSCloudFormation":   return "CloudFormation"
        case "AWSMarketplace":      return "Marketplace"
        case "CloudFrontPlans":     return "CloudFront plans"
        case "awskms":              return "KMS"
        case "ACM":                 return "Certificate Manager"
        default:                    return service
        }
    }
}

/// Month-to-date estimated charges for the whole account, free from CloudWatch.
///
/// `hasData` exists for the same reason `CostBreakdown.populatedDays` does. A brand-new
/// billing-alert subscription publishes nothing for several hours, and rendering that as
/// $0.00 would be the exact lie this app was written to avoid.
struct BillingSnapshot: Equatable, Codable {
    /// When AWS published the newest datapoint. Not when Watchtower fetched it — these can be
    /// hours apart, and the panel shows both.
    var publishedAt: Date?
    var total: Double
    var services: [BillingCharge]
    var currency: String
    var periodStart: Date
    /// Recent burn in dollars per day, or nil when there is too little history to divide by.
    var dailyRate: Double?
    var rateWindowDays: Double?
    var hasData: Bool

    /// Services AWS has not broken out, derived rather than assumed. Small negatives are
    /// rounding between the total and the per-service metrics, so they clamp to zero.
    var unattributed: Double {
        max(0, total - services.reduce(0) { $0 + $1.amount })
    }

    func daysRemaining(asOf now: Date = Date()) -> Double {
        let calendar = Calendar(identifier: .gregorian)
        guard let next = calendar.date(byAdding: .month, value: 1, to: periodStart) else { return 0 }
        return max(0, next.timeIntervalSince(now) / 86_400)
    }

    /// What the month is on course to cost: what has already been spent, plus the recent
    /// daily rate carried across the days that are left. Never a whole-month extrapolation of
    /// the average, which one-off charges make nonsense of.
    func projectedMonthEnd(asOf now: Date = Date()) -> Double? {
        // A negative running total means credits currently exceed charges. Projecting forward
        // from it would print a confident negative bill, which is not a claim worth making.
        guard hasData, total >= 0, let dailyRate else { return nil }
        return total + dailyRate * daysRemaining(asOf: now)
    }
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
