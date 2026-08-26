import Foundation

/// Counts every AWS API call the app makes, so the README's cost figure is measured rather
/// than estimated. Persisted, because a 24-hour measurement has to survive a restart.
actor CallMeter {

    struct Tally: Codable {
        var since: Date = Date()
        /// API name -> number of calls.
        var calls: [String: Int] = [:]
        /// GetMetricData is billed per *metric* returned, not per call.
        var metricsRequested: Int = 0
    }

    /// Published AWS prices, us-east-1, checked 2026-08-26.
    enum Price {
        static let perGetMetricDataMetric = 0.01 / 1000.0
        static let perCostExplorerRequest = 0.01
    }

    private var tally = Tally()
    private let url: URL

    init(directory: URL) {
        self.url = directory.appendingPathComponent("callmeter.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Tally.self, from: data) {
            tally = saved
        }
    }

    func record(_ api: String, metrics: Int = 0) {
        tally.calls[api, default: 0] += 1
        tally.metricsRequested += metrics
        save()
    }

    func snapshot() -> Tally { tally }

    /// Dollars spent since the meter was last reset.
    func costToDate() -> Double {
        let metricCost = Double(tally.metricsRequested) * Price.perGetMetricDataMetric
        let ceCost = Double(tally.calls["GetCostAndUsage", default: 0]) * Price.perCostExplorerRequest
        return metricCost + ceCost
    }

    func reset() {
        tally = Tally()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tally) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
