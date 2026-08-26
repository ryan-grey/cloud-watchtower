import Foundation

/// CloudWatch speaks the AWS Query protocol and answers in XML.
struct CloudWatchService {
    let client: AWSClient
    let config: Configuration

    private var host: String { "monitoring.\(config.region).amazonaws.com" }
    private let apiVersion = "2010-08-01"

    /// Free: DescribeAlarms falls inside CloudWatch's free API request allowance.
    func describeAlarm() async throws -> AlarmSnapshot {
        let root = try await client.query(
            service: "monitoring", host: host, region: config.region,
            api: "DescribeAlarms", version: apiVersion,
            params: ["AlarmNames.member.1": config.alarmName]
        )

        guard let member = root.find("MetricAlarms")?.first("member") else {
            throw AWSError(code: "AlarmNotFound",
                           message: "No alarm named “\(config.alarmName)”")
        }
        return AlarmSnapshot(
            name: member.first("AlarmName")?.trimmed ?? config.alarmName,
            state: member.first("StateValue")?.trimmed ?? "INSUFFICIENT_DATA",
            stateUpdated: AWSDate.parse(member.first("StateUpdatedTimestamp")?.trimmed ?? ""),
            reason: member.first("StateReason")?.trimmed ?? ""
        )
    }

    /// Billed: $0.01 per 1,000 metrics. Three metrics per call, one call.
    ///
    /// Both the 1-hour and 24-hour figures come out of this single request: we ask for hourly
    /// buckets across a 25-hour window and aggregate client-side. Asking the API for two
    /// windows separately would double the billable metric count and still not give us the
    /// request-weighted error rate we actually want.
    static let metricsPerCall = 3

    func getMetricData(now: Date = Date()) async throws -> MetricsSnapshot {
        var params: [String: String] = [
            "StartTime": SigV4.Format.iso8601(now.addingTimeInterval(-25 * 3600)),
            "EndTime": SigV4.Format.iso8601(now),
            "ScanBy": "TimestampAscending"
        ]

        let queries: [(id: String, metric: String, stat: String)] = [
            ("req",  "Requests",      "Sum"),
            ("e4xx", "4xxErrorRate",  "Average"),
            ("e5xx", "5xxErrorRate",  "Average")
        ]

        for (index, query) in queries.enumerated() {
            let prefix = "MetricDataQueries.member.\(index + 1)"
            params["\(prefix).Id"] = query.id
            params["\(prefix).MetricStat.Metric.Namespace"] = "AWS/CloudFront"
            params["\(prefix).MetricStat.Metric.MetricName"] = query.metric
            params["\(prefix).MetricStat.Metric.Dimensions.member.1.Name"] = "DistributionId"
            params["\(prefix).MetricStat.Metric.Dimensions.member.1.Value"] = config.distributionId
            // Region=Global is mandatory for CloudFront metrics; without it the metric
            // silently never reports and every value reads as missing.
            params["\(prefix).MetricStat.Metric.Dimensions.member.2.Name"] = "Region"
            params["\(prefix).MetricStat.Metric.Dimensions.member.2.Value"] = "Global"
            params["\(prefix).MetricStat.Period"] = "3600"
            params["\(prefix).MetricStat.Stat"] = query.stat
        }

        let root = try await client.query(
            service: "monitoring", host: host, region: config.region,
            api: "GetMetricData", version: apiVersion,
            params: params, billedMetrics: Self.metricsPerCall
        )

        var series: [String: [Date: Double]] = [:]
        for result in root.findAll("member") where result.first("Id") != nil {
            guard let id = result.first("Id")?.trimmed else { continue }
            let timestamps = result.first("Timestamps")?["member"].compactMap {
                AWSDate.parse($0.trimmed)
            } ?? []
            let values = result.first("Values")?["member"].compactMap { $0.doubleValue } ?? []
            var pairs: [Date: Double] = [:]
            for (time, value) in zip(timestamps, values) { pairs[time] = value }
            series[id] = pairs
        }

        let allTimestamps = Set(series.values.flatMap(\.keys)).sorted()
        let buckets = allTimestamps.map { time in
            HourBucket(timestamp: time,
                       requests: series["req"]?[time] ?? 0,
                       errorRate4xx: series["e4xx"]?[time],
                       errorRate5xx: series["e5xx"]?[time])
        }
        return MetricsSnapshot(buckets: buckets)
    }
}
