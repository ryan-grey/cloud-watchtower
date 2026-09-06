import Foundation

/// What Watchtower watches.
///
/// The defaults below are deliberately placeholders. Account IDs, distribution IDs and IAM
/// user names are not secrets, but publishing them lets a stranger construct valid ARNs for
/// your account, which is where targeted enumeration and credible phishing start. Real values
/// live in `defaults`, outside this repo:
///
/// ```sh
/// defaults write dev.ryangrey.watchtower accountId      -string "123456789012"
/// defaults write dev.ryangrey.watchtower distributionId -string "EXXXXXXXXXXXXX"
/// defaults write dev.ryangrey.watchtower alarmName      -string "cloudfront-5xx-error-rate"
/// defaults write dev.ryangrey.watchtower budgetName     -string "my-monthly-budget"
/// defaults write dev.ryangrey.watchtower profileName    -string "watchtower"
/// defaults write dev.ryangrey.watchtower region         -string "us-east-1"
/// ```
///
/// One optional knob, in seconds, floored at 300:
///
/// ```sh
/// defaults write dev.ryangrey.watchtower billingIntervalSeconds -float 900
/// ```
struct Configuration {
    var accountId: String
    var distributionId: String
    var alarmName: String
    var budgetName: String
    var profileName: String
    var region: String
    /// How often to poll AWS/Billing, in seconds. Exposed because it is the only interval in
    /// the app whose cost scales with the account: a personal account bills ~21 metrics a
    /// poll, an organisation with 60 active services bills three times that. Floored at 300 s
    /// so a typo cannot turn a cheap poll into a line item.
    var billingIntervalSeconds: Double

    static let minimumBillingInterval: Double = 300

    static let placeholderAccountId = "000000000000"
    static let placeholderDistributionId = "EXAMPLEDISTID0"

    static let defaults = Configuration(
        accountId: placeholderAccountId,
        distributionId: placeholderDistributionId,
        alarmName: "cloudfront-5xx-error-rate",
        budgetName: "monthly-budget",
        profileName: "watchtower",
        region: "us-east-1",
        billingIntervalSeconds: 900
    )

    /// False until the placeholders are replaced. Surfaced in the panel and the self-test so
    /// an unconfigured app says so plainly instead of failing with a confusing AWS error.
    var isConfigured: Bool {
        accountId != Configuration.placeholderAccountId
            && distributionId != Configuration.placeholderDistributionId
            && !accountId.isEmpty && !distributionId.isEmpty
    }

    static let notConfiguredMessage =
        "Not configured — set accountId and distributionId (see README)"

    static func load() -> Configuration {
        let d = UserDefaults.standard
        var config = Configuration.defaults
        if let v = d.string(forKey: "accountId"), !v.isEmpty { config.accountId = v }
        if let v = d.string(forKey: "distributionId"), !v.isEmpty { config.distributionId = v }
        if let v = d.string(forKey: "alarmName"), !v.isEmpty { config.alarmName = v }
        if let v = d.string(forKey: "budgetName"), !v.isEmpty { config.budgetName = v }
        if let v = d.string(forKey: "profileName"), !v.isEmpty { config.profileName = v }
        if let v = d.string(forKey: "region"), !v.isEmpty { config.region = v }
        let interval = d.double(forKey: "billingIntervalSeconds")
        if interval > 0 {
            config.billingIntervalSeconds = max(Configuration.minimumBillingInterval, interval)
        }
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
        d.set(billingIntervalSeconds, forKey: "billingIntervalSeconds")
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
