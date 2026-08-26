import Foundation

/// What the menu-bar glyph encodes.
///
/// The brief asked for two states, normal and warning. There are three, because "I cannot
/// reach AWS" must never render as "everything is fine" — a monitor that goes quiet when it
/// breaks is worse than no monitor.
enum Health {
    case ok
    case warning(reasons: [String])
    case unknown(reason: String)

    var systemImage: String {
        switch self {
        case .ok:      return "cloud"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "cloud.slash"
        }
    }

    var summary: String {
        switch self {
        case .ok: return "All clear"
        case .warning(let reasons): return reasons.joined(separator: " · ")
        case .unknown(let reason): return reason
        }
    }

    /// Staleness beyond which a value stops counting as evidence of health.
    static let staleAfter: TimeInterval = 15 * 60

    static func evaluate(alarm: Loaded<AlarmSnapshot>,
                         budget: Loaded<BudgetSnapshot>,
                         now: Date = Date()) -> Health {

        var reasons: [String] = []

        // Both inputs are free to poll, so if either is missing or stale we genuinely do not
        // know the state and must say so rather than defaulting to OK.
        let alarmStale = (alarm.age(asOf: now) ?? .greatestFiniteMagnitude) > staleAfter
        let budgetStale = (budget.age(asOf: now) ?? .greatestFiniteMagnitude) > staleAfter

        if let value = alarm.value, !alarmStale {
            if value.isAlarming { reasons.append("Alarm firing") }
            else if value.isUnknown { reasons.append("Alarm has no data") }
        }
        if let value = budget.value, !budgetStale, value.isOverEightyPercent {
            reasons.append(String(format: "Spend at %.0f%% of budget", value.fraction * 100))
        }

        if !reasons.isEmpty { return .warning(reasons: reasons) }

        if alarm.value == nil || budget.value == nil {
            return .unknown(reason: alarm.errorText ?? budget.errorText ?? "Waiting for first refresh")
        }
        if alarmStale || budgetStale {
            return .unknown(reason: "Data is stale")
        }
        return .ok
    }
}
