import Foundation

/// What Watchtower watches. Defaults describe ryangrey.dev; all of it is overridable from
/// UserDefaults so the repo can be public without being account-specific in a harmful way.
/// None of these are secrets — they are resource identifiers, and every one is useless
/// without credentials.
struct Configuration {
    var accountId: String
    var distributionId: String
    var alarmName: String
    var budgetName: String
    var profileName: String
    var region: String

    static let defaults = Configuration(
        accountId: "<ACCOUNT_ID>",
        distributionId: "EXAMPLEDISTID0",
        alarmName: "cloudfront-5xx-error-rate",
        budgetName: "monthly-budget",
        profileName: "watchtower",
        region: "us-east-1"
    )

    static func load() -> Configuration {
        let d = UserDefaults.standard
        var config = Configuration.defaults
        if let v = d.string(forKey: "accountId"), !v.isEmpty { config.accountId = v }
        if let v = d.string(forKey: "distributionId"), !v.isEmpty { config.distributionId = v }
        if let v = d.string(forKey: "alarmName"), !v.isEmpty { config.alarmName = v }
        if let v = d.string(forKey: "budgetName"), !v.isEmpty { config.budgetName = v }
        if let v = d.string(forKey: "profileName"), !v.isEmpty { config.profileName = v }
        if let v = d.string(forKey: "region"), !v.isEmpty { config.region = v }
        return config
    }

    func save() {
        let d = UserDefaults.standard
        d.set(accountId, forKey: "accountId")
        d.set(distributionId, forKey: "distributionId")
        d.set(alarmName, forKey: "alarmName")
        d.set(budgetName, forKey: "budgetName")
        d.set(profileName, forKey: "profileName")
        d.set(region, forKey: "region")
    }
}

enum AWSDate {
    /// AWS mixes fractional-second and whole-second ISO 8601. Try both.
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
