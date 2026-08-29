import SwiftUI

/// Section heading.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// Renders a failure without ever implying a value. Used everywhere a card can fail.
struct FailureNote: View {
    let message: String
    let lastSuccess: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(lastSuccess == nil
                 ? "Never refreshed successfully."
                 : "Last good data \(Fmt.relative(lastSuccess)).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

/// Month-to-date spend against the budget. Deliberately handles fraction > 1: this account's
/// August 2026 sits at 340% because of a one-time domain transfer, and a bar that silently
/// clamps to "full" would hide how far over it is.
struct BudgetBar: View {
    let snapshot: BudgetSnapshot

    private var fill: Color {
        if snapshot.fraction >= 1 { return .red }
        if snapshot.fraction >= 0.8 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.money(snapshot.actual))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(Fmt.money(snapshot.limit)) \(snapshot.unit)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(snapshot.fraction))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fill)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(2, geometry.size.width * min(snapshot.fraction, 1)))
                    // Over budget: hatch the whole bar so "full" and "way past full" differ.
                    if snapshot.fraction > 1 {
                        Capsule()
                            .strokeBorder(Color.red.opacity(0.9), lineWidth: 1.5)
                    }
                }
            }
            .frame(height: 7)

            if snapshot.fraction > 1 {
                Text("Over budget by \(Fmt.money(snapshot.actual - snapshot.limit)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }
}

/// A metric card's rows, rendered across the group's windows.
///
/// Knows nothing about CloudFront, Lambda or anything else: it reads `DerivedSpec` rows off
/// the group and asks the snapshot for each value. That is what lets one panel hold a
/// distribution's error rates and a function's duration without either card being a special
/// case.
struct MetricGrid: View {
    let group: MetricGroup
    let snapshot: MetricsSnapshot
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(" ").font(.system(size: 10))
                ForEach(group.derived, id: \.label) { spec in
                    Text(spec.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ForEach(group.windows, id: \.self) { hours in
                VStack(alignment: .trailing, spacing: 6) {
                    Text(Fmt.windowLabel(hours))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ForEach(group.derived, id: \.label) { spec in
                        let value = snapshot.value(spec, hours: hours, now: now)
                        Text(Fmt.metric(value, unit: spec.unit))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(tint(spec, value))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Cosmetic only. Metrics never vote on the glyph, so a threshold here cannot make a
    /// broken monitor look healthy or the reverse.
    private func tint(_ spec: DerivedSpec, _ value: Double?) -> Color {
        guard let value, let limit = spec.warnAbove, value > limit else { return .primary }
        return .orange
    }
}
