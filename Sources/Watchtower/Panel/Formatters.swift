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

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func duration(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 { return String(format: "%.2fs", milliseconds / 1000) }
        return String(format: "%.0fms", milliseconds)
    }

    static func bytes(_ value: Double) -> String {
        if value >= 1_073_741_824 { return String(format: "%.2f GB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return String(format: "%.0f B", value)
    }

    /// The one place a derived metric becomes text. nil is never rendered as a number:
    /// an empty window and a zero denominator both mean "undefined", and printing 0 for
    /// either is the specific lie this app exists to avoid.
    static func metric(_ value: Double?, unit: MetricUnit) -> String {
        guard let value else { return "—" }
        switch unit {
        case .count:        return count(value)
        case .percent:      return rate(value)
        case .milliseconds: return duration(value)
        case .bytes:        return bytes(value)
        }
    }

    static func windowLabel(_ hours: Double) -> String {
        if hours < 1 { return "\(Int(hours * 60))m" }
        if hours == 1 { return "Last hour" }
        if hours < 48 { return "Last \(Int(hours))h" }
        return "Last \(Int(hours / 24))d"
    }
}

extension Health {
    var tint: Color {
        switch self {
        case .ok:      return .green
        case .warning: return .orange
        case .unknown: return .secondary
        }
    }
}
