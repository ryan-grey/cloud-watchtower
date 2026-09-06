import Foundation

/// Whole-account estimated charges, from CloudWatch's `AWS/Billing` namespace.
///
/// This is the cheap half of Watchtower's cost picture. Cost Explorer is authoritative, knows
/// about credits and refunds, and costs $0.01 a question, so it stays on a button. `AWS/Billing`
/// answers the different question — "what is this month going to cost me" — for $0.01 per
/// 1,000 metrics, which is cheap enough to put on a timer.
///
/// Two things about this namespace routinely mislead people:
///
/// 1. It exists only after **Receive CloudWatch billing alerts** is ticked in Billing
///    preferences, and only ever in us-east-1 no matter where the account's resources run.
///    An empty namespace is a setup state, not a failure, and is reported as `notEnabled`
///    rather than as $0.00.
/// 2. `EstimatedCharges` is cumulative within the billing month and resets at the boundary.
///    It is a running total, not a rate, so the newest datapoint is month-to-date spend and
///    the difference between two datapoints is what was spent in between.
struct BillingService {
    let client: AWSClient

    /// Billing metrics are published to us-east-1 only.
    private let host = "monitoring.us-east-1.amazonaws.com"
    private let region = "us-east-1"
    private let apiVersion = "2010-08-01"

    /// AWS publishes a new billing datapoint every few hours. Six-hour buckets keep the
    /// month's series short enough to stay well inside one response.
    private let period = 21_600

    /// GetMetricData bills per metric requested, so the per-service fan-out is capped. In a
    /// personal account this is never reached; it exists so an organisation with 60 active
    /// services cannot quietly turn a 15-minute poll into a real line item.
    static let maximumServices = 24

    /// The account-total query carries no ServiceName dimension.
    private static let totalId = "acct"

    enum Availability: Equatable {
        case enabled([String])   // service names published in this namespace
        case notEnabled
    }

    /// Free — ListMetrics is not a billed CloudWatch API.
    ///
    /// Returns the services AWS is currently publishing charges for. An empty namespace means
    /// billing alerts have never been enabled, which is a different state from "no charges".
    func availability() async throws -> Availability {
        var services: [String] = []
        var token: String?
        var pages = 0

        repeat {
            var params = ["Namespace": "AWS/Billing", "MetricName": "EstimatedCharges"]
            if let token { params["NextToken"] = token }

            let root = try await client.query(
                service: "monitoring", host: host, region: region,
                api: "ListMetrics", version: apiVersion, params: params
            )

            for metric in root.find("Metrics")?["member"] ?? [] {
                let dimensions = metric.find("Dimensions")?["member"] ?? []
                let named = dimensions.compactMap { dimension -> (String, String)? in
                    guard let name = dimension.first("Name")?.trimmed,
                          let value = dimension.first("Value")?.trimmed else { return nil }
                    return (name, value)
                }
                // A metric dimensioned only by Currency is the account total, not a service.
                if let service = named.first(where: { $0.0 == "ServiceName" })?.1 {
                    services.append(service)
                }
            }

            let next = root.find("NextToken")?.trimmed
            token = (next?.isEmpty == false) ? next : nil
            pages += 1
        } while token != nil && pages < 5

        let unique = Array(Set(services)).sorted()
        return unique.isEmpty ? .notEnabled : .enabled(unique)
    }

    /// How many metrics a fetch for these services will be billed for.
    static func billedMetrics(for services: [String]) -> Int {
        min(services.count, maximumServices) + 1     // + the account total
    }

    /// Billed: $0.01 per 1,000 metrics. One call, one metric per service plus the total.
    func currentCharges(services: [String], now: Date = Date()) async throws -> BillingSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let periodStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let tracked = Array(services.prefix(Self.maximumServices))

        var params: [String: String] = [
            // A day of lead-in before the month boundary so the first datapoint of the month
            // is never the only one we have to reason about.
            "StartTime": SigV4.Format.iso8601(periodStart.addingTimeInterval(-86_400)),
            "EndTime": SigV4.Format.iso8601(now),
            "ScanBy": "TimestampAscending"
        ]

        // Ids have to be valid identifiers, and service names are not, so they are positional
        // and mapped back afterwards.
        var idToService: [String: String] = [:]
        var index = 0

        func addQuery(id: String, serviceName: String?) {
            let prefix = "MetricDataQueries.member.\(index + 1)"
            params["\(prefix).Id"] = id
            params["\(prefix).MetricStat.Metric.Namespace"] = "AWS/Billing"
            params["\(prefix).MetricStat.Metric.MetricName"] = "EstimatedCharges"
            params["\(prefix).MetricStat.Metric.Dimensions.member.1.Name"] = "Currency"
            params["\(prefix).MetricStat.Metric.Dimensions.member.1.Value"] = "USD"
            if let serviceName {
                params["\(prefix).MetricStat.Metric.Dimensions.member.2.Name"] = "ServiceName"
                params["\(prefix).MetricStat.Metric.Dimensions.member.2.Value"] = serviceName
                idToService[id] = serviceName
            }
            params["\(prefix).MetricStat.Period"] = String(period)
            // Maximum, not Average: EstimatedCharges is a cumulative gauge, so the largest
            // value in a bucket is the state at the end of it. Averaging would smear the
            // running total backwards and under-report every figure on screen.
            params["\(prefix).MetricStat.Stat"] = "Maximum"
            index += 1
        }

        addQuery(id: Self.totalId, serviceName: nil)
        for (position, service) in tracked.enumerated() {
            addQuery(id: "s\(position)", serviceName: service)
        }

        let root = try await client.query(
            service: "monitoring", host: host, region: region,
            api: "GetMetricData", version: apiVersion,
            params: params, billedMetrics: index
        )

        var series: [String: [(Date, Double)]] = [:]
        for result in root.findAll("member") where result.first("Id") != nil {
            guard let id = result.first("Id")?.trimmed else { continue }
            let timestamps = result.first("Timestamps")?["member"].compactMap {
                AWSDate.parse($0.trimmed)
            } ?? []
            let values = result.first("Values")?["member"].compactMap { $0.doubleValue } ?? []
            series[id] = Array(zip(timestamps, values)).sorted { $0.0 < $1.0 }
        }

        // Only datapoints inside the current billing month count: EstimatedCharges resets at
        // the boundary, so a lead-in point from last month is a different month's total.
        func thisMonth(_ id: String) -> [(Date, Double)] {
            (series[id] ?? []).filter { $0.0 >= periodStart }
        }

        let accountSeries = thisMonth(Self.totalId)
        let charges: [BillingCharge] = tracked.enumerated().compactMap { position, service in
            guard let latest = thisMonth("s\(position)").last else { return nil }
            return BillingCharge(service: service, amount: latest.1)
        }.sorted { $0.amount > $1.amount }

        let (rate, window) = Self.dailyRate(from: accountSeries, now: now)

        return BillingSnapshot(
            publishedAt: accountSeries.last?.0,
            total: accountSeries.last?.1 ?? 0,
            services: charges,
            currency: "USD",
            periodStart: periodStart,
            dailyRate: rate,
            rateWindowDays: window,
            hasData: !accountSeries.isEmpty
        )
    }

    /// A projection needs at least this many gaps between datapoints before a median means
    /// anything. At six-hour publishing that is a bit over a day of history.
    static let minimumIntervals = 4

    /// Dollars per day over the recent past, used to project the rest of the month.
    ///
    /// This is the **median of the per-interval burn rates**, not the endpoint difference
    /// divided by elapsed time, and the distinction is the whole point. A one-off charge — a
    /// domain transfer, a support plan — is real spend that belongs in the month-to-date total
    /// but says nothing about what the remaining days will cost. An endpoint difference
    /// amortises that spike across the window and forecasts it recurring forever: this
    /// account's August $17 domain transfer, measured that way five days into a month, projects
    /// about $102. A median sees the spike as one interval out of twenty and ignores it,
    /// returning $17 — the charge, and nothing more.
    ///
    /// A trailing window alone does not fix this. Early in the month the window is longer than
    /// the data, so the spike is inside it either way.
    static func dailyRate(from series: [(Date, Double)],
                          now: Date,
                          preferredWindowDays: Double = 7) -> (Double?, Double?) {
        let cutoff = now.addingTimeInterval(-preferredWindowDays * 86_400)
        let recent = series.filter { $0.0 >= cutoff }
        // Early in a month the window holds everything, which is correct: the median is what
        // makes that safe, not the window.
        let points = recent.count > minimumIntervals ? recent : series
        guard points.count > minimumIntervals else { return (nil, nil) }

        var rates: [Double] = []
        for (earlier, later) in zip(points, points.dropFirst()) {
            let gap = later.0.timeIntervalSince(earlier.0) / 86_400
            guard gap > 0 else { continue }
            // Credits and refunds push the running total down. A negative interval is not
            // negative future burn, so it floors at zero rather than subsidising the forecast.
            rates.append(max(0, later.1 - earlier.1) / gap)
        }
        guard rates.count >= minimumIntervals else { return (nil, nil) }

        rates.sort()
        let middle = rates.count / 2
        let median = rates.count.isMultiple(of: 2)
            ? (rates[middle - 1] + rates[middle]) / 2
            : rates[middle]

        let span = points.last!.0.timeIntervalSince(points.first!.0) / 86_400
        return (median, span)
    }
}
