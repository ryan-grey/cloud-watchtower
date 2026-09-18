import Foundation

/// The text beside the menu-bar glyph when `menuBarCost` is on: "$4.12 · in 12d 6h", or
/// "31% · in 12d 6h" in the percent style. Pure, so `--selftest` can print the same line the
/// status item would draw, and so the rules live in one place.
///
/// The rule the rest of the app follows applies here too: no figure beats a made-up one.
/// When there is nothing honest to show the result is nil and the status item stays icon-only.
enum MenuBarTitle {

    static func make(billing: BillingSnapshot?,
                     budget: BudgetSnapshot?,
                     billingNotEnabled: Bool,
                     now: Date,
                     style: String) -> String? {
        // The panel lets "not enabled" override whatever is cached, so this does too: a
        // snapshot restored from disk for an account that is not publishing is not a reading.
        let billing = billingNotEnabled ? nil : billing

        // Switched on, but nothing published for this month yet. The panel says "this is not
        // a $0 month" here, and the menu bar says nothing rather than contradict it.
        if let billing, !billing.hasData { return nil }

        let amount: Double
        if let billing {
            amount = billing.total
        } else if let budget {
            // AWS Budgets' own actual-spend figure: free, already polled, a few hours coarser.
            amount = budget.actual
        } else {
            return nil
        }

        // Percent needs a budget to be a percent of. Without one it falls back to the amount
        // silently rather than showing nothing.
        let reading: String
        if style == "percent", let budget {
            reading = Fmt.percent(budget.fraction)
        } else {
            reading = Fmt.moneyAdaptive(amount)
        }

        let end = periodEnd(billing: billing, now: now)
        return "\(reading) · \(Fmt.countdown(to: end, from: now))"
    }

    /// When the current billing period closes. AWS bills by calendar month in UTC, so this is
    /// `periodStart` plus one month when a billing snapshot exists (the same instant
    /// `Fmt.monthEndDay` names), and the start of the next UTC month otherwise.
    static func periodEnd(billing: BillingSnapshot?, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        let start = billing?.periodStart
            ?? calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? now
        return calendar.date(byAdding: .month, value: 1, to: start) ?? now
    }
}
