import Foundation

/// AWS Budgets. Free to call, and the reason Watchtower does not need Cost Explorer for its
/// headline number: DescribeBudget already returns month-to-date actual spend against the
/// limit, which is exactly the progress bar. AWS recalculates it roughly three times a day,
/// which is why it is polled slowly rather than every minute.
struct BudgetsService {
    let client: AWSClient
    let config: Configuration

    func describeBudget() async throws -> BudgetSnapshot {
        let response = try await client.json(
            service: "budgets",
            host: "budgets.amazonaws.com",     // global endpoint, signed against us-east-1
            region: "us-east-1",
            target: "AWSBudgetServiceGateway.DescribeBudget",
            api: "DescribeBudget",
            payload: ["AccountId": config.accountId, "BudgetName": config.budgetName]
        )

        guard let budget = response["Budget"] as? [String: Any] else {
            throw AWSError(code: "BudgetNotFound",
                           message: "No budget named “\(config.budgetName)”")
        }

        let limitObject = budget["BudgetLimit"] as? [String: Any]
        let spend = budget["CalculatedSpend"] as? [String: Any]
        let actual = spend?["ActualSpend"] as? [String: Any]

        // Amounts arrive as strings; a Double cast would silently produce nil.
        let limit = (limitObject?["Amount"] as? String).flatMap(Double.init) ?? 0
        let actualAmount = (actual?["Amount"] as? String).flatMap(Double.init) ?? 0

        var lastUpdated: Date?
        if let epoch = budget["LastUpdatedTime"] as? Double {
            lastUpdated = Date(timeIntervalSince1970: epoch)
        }

        return BudgetSnapshot(
            name: budget["BudgetName"] as? String ?? config.budgetName,
            limit: limit,
            actual: actualAmount,
            unit: (limitObject?["Unit"] as? String) ?? "USD",
            lastUpdated: lastUpdated
        )
    }
}
