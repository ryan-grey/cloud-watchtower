import Foundation

/// One distinct thing to ask CloudWatch for.
///
/// The dedup key is the whole point: two targets watching the same Lambda, or a shared
/// distribution appearing in two groups, must be billed once. GetMetricData charges per
/// *metric requested*, so identical queries collapsing into one wire entry is the only
/// batching that saves money.
struct MetricQuery: Hashable {
    let namespace: String
    let metricName: String
    let dimensions: [String: String]
    let stat: String
    let period: Int
    /// Credentials and endpoint are part of identity: the same metric name in two regions is
    /// two different metrics, and cannot share a request.
    let region: String
    let profile: String

    init(group: MetricGroup, series: SeriesSpec, region: String, profile: String) {
        self.namespace = group.namespace
        self.metricName = series.metricName
        self.dimensions = group.dimensions
        self.stat = series.stat
        self.period = group.period
        self.region = region
        self.profile = profile
    }

    var canonicalKey: String {
        let dims = dimensions.keys.sorted().map { "\($0)=\(dimensions[$0]!)" }.joined(separator: ";")
        return "\(profile)|\(region)|\(namespace)|\(metricName)|\(stat)|\(period)|\(dims)"
    }

    static func == (a: MetricQuery, b: MetricQuery) -> Bool { a.canonicalKey == b.canonicalKey }
    func hash(into hasher: inout Hasher) { hasher.combine(canonicalKey) }
}

/// CloudWatch speaks the AWS Query protocol and answers in XML.
struct CloudWatchService {
    let client: AWSClient

    private func host(_ region: String) -> String { "monitoring.\(region).amazonaws.com" }
    private let apiVersion = "2010-08-01"

    /// GetMetricData accepts at most 500 queries per call.
    static let maximumQueriesPerCall = 500

    // MARK: - Alarms (free)

    /// Free: DescribeAlarms falls inside CloudWatch's free API request allowance.
    ///
    /// Batched by name because it costs nothing to do so and keeps the request count flat as
    /// targets are added — a hundred alarms is still one call per region, not a hundred.
    func describeAlarms(names: [String],
                        region: String,
                        profile: String) async throws -> [String: AlarmSnapshot] {
        guard !names.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for (index, name) in names.enumerated() {
            params["AlarmNames.member.\(index + 1)"] = name
        }

        let root = try await client.query(
            service: "monitoring", host: host(region), region: region, profile: profile,
            api: "DescribeAlarms", version: apiVersion, params: params
        )

        var found: [String: AlarmSnapshot] = [:]
        for member in root.find("MetricAlarms")?["member"] ?? [] {
            guard let name = member.first("AlarmName")?.trimmed else { continue }
            found[name] = AlarmSnapshot(
                name: name,
                state: member.first("StateValue")?.trimmed ?? "INSUFFICIENT_DATA",
                stateUpdated: AWSDate.parse(member.first("StateUpdatedTimestamp")?.trimmed ?? ""),
                reason: member.first("StateReason")?.trimmed ?? ""
            )
        }
        return found
    }

    // MARK: - Metrics (billed)

    /// Fetches every metric group in one region/profile, deduplicated, and fans the results
    /// back out to the targets that asked for them.
    ///
    /// Cost notes, because this is the function the product thesis lives in:
    ///
    /// - Billing is **$0.01 per 1,000 metrics requested**, not per request. Splitting queries
    ///   across calls costs exactly what one call costs, so batching here buys throttling
    ///   headroom and latency — not money. Deduplication is what buys money.
    /// - Datapoints are free. The window is therefore widened to the largest any group asked
    ///   for, so one request satisfies every group, and both the 1-hour and 24-hour figures
    ///   are computed client-side from the same series. Asking for two windows separately
    ///   would double the billable metric count and still not give a request-weighted rate.
    /// - Only series a displayed row actually reads are requested. A series nothing renders
    ///   is billed on every poll forever.
    func fetchMetrics(targets: [WatchTarget],
                      region: String,
                      profile: String,
                      now: Date = Date()) async throws -> [UUID: MetricsSnapshot] {

        // 1. Collect every (target, seriesID) -> query, deduplicating queries.
        var wireIDs: [MetricQuery: String] = [:]
        var ordered: [(id: String, query: MetricQuery)] = []
        var wanted: [UUID: [(seriesID: String, wireID: String)]] = [:]
        var widestWindow: Double = 1

        for target in targets {
            guard let group = target.metricGroup else { continue }
            widestWindow = max(widestWindow, group.windowHours)
            for series in group.usedSeries {
                let query = MetricQuery(group: group, series: series,
                                        region: region, profile: profile)
                let wireID: String
                if let existing = wireIDs[query] {
                    wireID = existing
                } else {
                    wireID = "q\(ordered.count)"
                    wireIDs[query] = wireID
                    ordered.append((wireID, query))
                }
                wanted[target.id, default: []].append((series.id, wireID))
            }
        }
        guard !ordered.isEmpty else { return [:] }

        // 2. Issue the calls and merge the raw series.
        var raw: [String: [MetricPoint]] = [:]
        for chunk in stride(from: 0, to: ordered.count, by: Self.maximumQueriesPerCall) {
            let slice = Array(ordered[chunk ..< min(chunk + Self.maximumQueriesPerCall,
                                                    ordered.count)])
            let merged = try await request(slice, region: region, profile: profile,
                                           windowHours: widestWindow, now: now)
            raw.merge(merged) { _, new in new }
        }

        // 3. Fan out to the targets that asked.
        var snapshots: [UUID: MetricsSnapshot] = [:]
        for (targetID, mappings) in wanted {
            let series = mappings.map { mapping in
                MetricSeries(id: mapping.seriesID, points: raw[mapping.wireID] ?? [])
            }
            let period = targets.first { $0.id == targetID }?.metricGroup?.period ?? 3600
            snapshots[targetID] = MetricsSnapshot(series: series, period: period)
        }
        return snapshots
    }

    private func request(_ queries: [(id: String, query: MetricQuery)],
                         region: String,
                         profile: String,
                         windowHours: Double,
                         now: Date) async throws -> [String: [MetricPoint]] {

        var params: [String: String] = [
            "StartTime": SigV4.Format.iso8601(now.addingTimeInterval(-windowHours * 3600)),
            "EndTime": SigV4.Format.iso8601(now),
            "ScanBy": "TimestampAscending"
        ]

        for (index, entry) in queries.enumerated() {
            let prefix = "MetricDataQueries.member.\(index + 1)"
            params["\(prefix).Id"] = entry.id
            params["\(prefix).MetricStat.Metric.Namespace"] = entry.query.namespace
            params["\(prefix).MetricStat.Metric.MetricName"] = entry.query.metricName
            // Sorted so the signed body is deterministic for a given query set.
            for (position, key) in entry.query.dimensions.keys.sorted().enumerated() {
                let dimension = "\(prefix).MetricStat.Metric.Dimensions.member.\(position + 1)"
                params["\(dimension).Name"] = key
                params["\(dimension).Value"] = entry.query.dimensions[key]!
            }
            params["\(prefix).MetricStat.Period"] = String(entry.query.period)
            params["\(prefix).MetricStat.Stat"] = entry.query.stat
        }

        let root = try await client.query(
            service: "monitoring", host: host(region), region: region, profile: profile,
            api: "GetMetricData", version: apiVersion,
            params: params, billedMetrics: queries.count
        )

        var series: [String: [MetricPoint]] = [:]
        for result in root.findAll("member") where result.first("Id") != nil {
            guard let id = result.first("Id")?.trimmed else { continue }
            let timestamps = result.first("Timestamps")?["member"].compactMap {
                AWSDate.parse($0.trimmed)
            } ?? []
            let values = result.first("Values")?["member"].compactMap { $0.doubleValue } ?? []
            series[id] = zip(timestamps, values)
                .map { MetricPoint(t: $0.0, v: $0.1) }
                .sorted { $0.t < $1.t }
        }
        return series
    }
}
