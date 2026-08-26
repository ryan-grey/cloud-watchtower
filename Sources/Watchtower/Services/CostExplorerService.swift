import Foundation

/// Cost Explorer — the only read API in this account that costs money, at ~$0.01 per request.
///
/// It is therefore NEVER on a timer. It runs only when the user presses the button, the
/// result is cached for 24 hours, and the panel labels the button with its own price. One
/// GroupBy per question, one call per question.
struct CostExplorerService {
    let client: AWSClient
    let config: Configuration

    static let cacheLifetime: TimeInterval = 24 * 3600

    func monthToDateByService(now: Date = Date()) async throws -> CostBreakdown {
        let calendar = Calendar(identifier: .gregorian)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        // CE's end date is exclusive and its data lags ~24h, so today is the right bound.
        let start = SigV4.Format.yyyymmdd(startOfMonth)
        let end = SigV4.Format.yyyymmdd(now)

        let response = try await client.json(
            service: "ce",
            host: "ce.us-east-1.amazonaws.com",   // Cost Explorer is us-east-1 only
            region: "us-east-1",
            target: "AWSInsightsIndexService.GetCostAndUsage",
            api: "GetCostAndUsage",
            payload: [
                "TimePeriod": ["Start": start, "End": end],
                "Granularity": "DAILY",
                "Metrics": ["UnblendedCost"],
                "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]]
            ]
        )

        let results = response["ResultsByTime"] as? [[String: Any]] ?? []
        var totals: [String: Double] = [:]
        var populatedDays = 0

        for day in results {
            let groups = day["Groups"] as? [[String: Any]] ?? []
            // A day with zero group objects means CE has no data for it at all, which is
            // very different from a day whose services all cost $0.00. Conflating the two is
            // how an unpopulated backfill gets mistaken for a free month.
            if !groups.isEmpty { populatedDays += 1 }
            for group in groups {
                guard let name = (group["Keys"] as? [String])?.first,
                      let metrics = group["Metrics"] as? [String: Any],
                      let cost = metrics["UnblendedCost"] as? [String: Any],
                      let amount = (cost["Amount"] as? String).flatMap(Double.init) else { continue }
                totals[name, default: 0] += amount
            }
        }

        let services = totals.sorted { $0.value > $1.value }
            .map { ServiceCost(name: $0.key, amount: $0.value) }

        return CostBreakdown(periodStart: start,
                             periodEnd: end,
                             services: services,
                             total: totals.values.reduce(0, +),
                             populatedDays: populatedDays,
                             totalDays: max(results.count, 1))
    }
}
