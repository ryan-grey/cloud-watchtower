import Foundation
import SwiftUI

enum Fmt {
    static func relative(_ date: Date?, asOf now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        if seconds < 5400 { return "\(Int(seconds / 60))m ago" }
        if seconds < 172_800 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    static func count(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if value >= 1000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }

    /// nil means "no traffic, so the rate is undefined" — never render that as 0%.
    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0%" }
        if value < 0.01 { return "<0.01%" }
        return String(format: "%.2f%%", value)
    }

    static func money(_ value: Double, places: Int = 2) -> String {
        String(format: "$%.\(places)f", value)
    }

    /// Cents are the wrong resolution for an account that spends fractions of one. Sub-dollar
    /// figures keep four places so a real charge never rounds away to "$0.00" — the reading
    /// that sends you looking for a bug in the dashboard instead of at your bill.
    static func moneyAdaptive(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if abs(value) < 0.01 { return money(value, places: 4) }
        if abs(value) < 1 { return money(value, places: 3) }
        return money(value, places: 2)
    }

    /// "Sep 30" — the day the current billing period closes.
    static func monthEndDay(from periodStart: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let next = calendar.date(byAdding: .month, value: 1, to: periodStart),
              let last = calendar.date(byAdding: .day, value: -1, to: next) else { return "month end" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: last)
    }

    static func days(_ value: Double) -> String {
        value < 1.5 ? "1 day" : String(format: "%.0f days", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}

extension Health {
    /// Health maps onto a Primer role, so the glyph, the Label pill and any flash all draw
    /// from one decision rather than three hand-picked colours.
    var role: PrimerRole {
        switch self {
        case .ok:      return .success
        case .warning: return .attention
        case .unknown: return .neutral
        }
    }

    var tint: Color { role.fg }

    /// Short enough for a Primer Label. The full sentence goes underneath the header.
    var labelText: String {
        switch self {
        case .ok:      return "All clear"
        case .warning: return "Attention"
        case .unknown: return "Unknown"
        }
    }

    var isOK: Bool { if case .ok = self { return true }; return false }
    var isWarning: Bool { if case .warning = self { return true }; return false }
}
