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

    /// Only alarms and budgets vote. Both are free to poll, so they can be fresh enough to
    /// trust; metrics are billed and deliberately lazy, and a glyph driven by a 15-minute-old
    /// number would either be wrong or force the poll rate — and therefore the bill — up.
    ///
    /// Composition matters as much as the verdict: with N targets a single firing alarm must
    /// not hide a second one, and an unreachable card must not be averaged away by healthy
    /// neighbours. Every reason is listed; any unknown outranks a clean sweep.
    static func evaluate(cards: [TargetCard], now: Date = Date()) -> Health {
        let voting = cards.filter(\.target.isFree)
        guard !voting.isEmpty else {
            return .unknown(reason: cards.isEmpty
                            ? "No watch targets configured"
                            : "Watching metrics only — no alarm or budget to judge health")
        }

        var reasons: [String] = []
        var missing: [TargetCard] = []
        var stale: [TargetCard] = []

        for card in voting {
            guard let payload = card.state.value else { missing.append(card); continue }
            if card.state.isStale(asOf: now) { stale.append(card); continue }

            if let alarm = payload.alarm {
                if alarm.isAlarming { reasons.append("\(card.target.displayName) firing") }
                else if alarm.isUnknown { reasons.append("\(card.target.displayName) has no data") }
            }
            if let budget = payload.budget, budget.isOverEightyPercent {
                reasons.append(String(format: "%@ at %.0f%% of budget",
                                      card.target.displayName, budget.fraction * 100))
            }
        }

        if !reasons.isEmpty { return .warning(reasons: reasons) }

        if let first = missing.first {
            let detail = first.state.errorText ?? "Waiting for first refresh"
            return .unknown(reason: missing.count == 1
                            ? "\(first.target.displayName): \(detail)"
                            : "\(missing.count) targets have no data")
        }
        if let first = stale.first {
            return .unknown(reason: stale.count == 1
                            ? "\(first.target.displayName) is stale"
                            : "\(stale.count) targets are stale")
        }
        return .ok
    }
}
