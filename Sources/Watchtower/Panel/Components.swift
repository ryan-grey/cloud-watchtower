import SwiftUI

/// Renders a failure without ever implying a value. Used everywhere a box can fail.
///
/// This is Primer's danger `flash`, not a line of red text: a failed reading has to be
/// visually louder than a successful one, because the mistake this app exists to prevent is
/// reading a stale or missing number as a real one.
struct FailureNote: View {
    let message: String
    let lastSuccess: Date?

    var body: some View {
        PrimerFlash(role: .danger) {
            Text(message)
                .font(Primer.small)
                .foregroundStyle(Primer.fgDefault)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(lastSuccess == nil
                 ? "Never refreshed successfully."
                 : "Last good data \(Fmt.relative(lastSuccess)).")
                .font(Primer.caption)
                .foregroundStyle(Primer.fgMuted)
        }
    }
}

/// The placeholder shown in a box that has never loaded.
struct WaitingNote: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text("Waiting for first refresh…")
                .font(Primer.small)
        }
        .foregroundStyle(Primer.fgMuted)
    }
}

/// Month-to-date spend against the budget, as Primer's `ProgressBar` under a headline figure.
///
/// Deliberately handles fraction > 1: this account's August 2026 sits at 340% because of a
/// one-time domain transfer, and a bar that silently clamps to "full" would hide how far over
/// it is. Primer has no over-100% state, so the bar keeps its role colour and a danger flash
/// carries the overage.
struct BudgetBar: View {
    let snapshot: BudgetSnapshot

    private var role: PrimerRole {
        if snapshot.fraction >= 1 { return .danger }
        if snapshot.fraction >= 0.8 { return .attention }
        return .success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.money(snapshot.actual))
                    .font(Primer.text(18, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Primer.fgDefault)
                Text("of \(Fmt.money(snapshot.limit)) \(snapshot.unit)")
                    .font(Primer.small)
                    .foregroundStyle(Primer.fgMuted)
                Spacer(minLength: 6)
                PrimerLabel(text: Fmt.percent(snapshot.fraction), role: role)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Primer.neutralMuted)
                    Capsule()
                        .fill(role.emphasis)
                        .frame(width: max(2, geometry.size.width * min(snapshot.fraction, 1)))
                }
            }
            .frame(height: 8)

            if snapshot.fraction > 1 {
                PrimerFlash(role: .danger, icon: "exclamationmark.octagon.fill") {
                    Text("Over budget by \(Fmt.money(snapshot.actual - snapshot.limit)).")
                        .font(Primer.small)
                        .foregroundStyle(Primer.fgDefault)
                }
            }
        }
    }
}

/// The 1h / 24h metric grid, laid out as a Primer table: a `canvas.subtle` head row, hairline
/// rules between rows, and right-aligned monospaced figures so the columns actually compare.
struct MetricGrid: View {
    let snapshot: MetricsSnapshot

    private struct Column: Identifiable {
        let id: String
        let hours: Double
    }
    private let columns = [Column(id: "1h", hours: 1), Column(id: "24h", hours: 24)]

    var body: some View {
        VStack(spacing: 0) {
            headRow
            PrimerRule()
            row("Requests") { column in
                figure(Fmt.count(snapshot.requests(hours: column.hours)))
            }
            PrimerRule()
            row("4xx rate") { column in
                figure(Fmt.rate(snapshot.errorRate(hours: column.hours, kind: .client)),
                       role: (snapshot.errorRate(hours: column.hours, kind: .client) ?? 0) >= 5
                             ? .attention : nil)
            }
            PrimerRule()
            row("5xx rate") { column in
                figure(Fmt.rate(snapshot.errorRate(hours: column.hours, kind: .server)),
                       role: (snapshot.errorRate(hours: column.hours, kind: .server) ?? 0) >= 1
                             ? .danger : nil)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                .strokeBorder(Primer.borderDefault, lineWidth: Primer.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: Primer.radius, style: .continuous))
    }

    private var headRow: some View {
        HStack(spacing: 0) {
            Text("Metric")
                .font(Primer.text(10, .semibold))
                .foregroundStyle(Primer.fgMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                Text(column.id)
                    .font(Primer.text(10, .semibold))
                    .foregroundStyle(Primer.fgMuted)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Primer.canvasSubtle)
    }

    private func row(_ label: String,
                     @ViewBuilder cell: @escaping (Column) -> some View) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(Primer.small)
                .foregroundStyle(Primer.fgDefault)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                cell(column).frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Primer.canvasDefault)
    }

    private func figure(_ text: String, role: PrimerRole? = nil) -> some View {
        Text(text)
            .font(Primer.mono(11, .medium))
            .foregroundStyle(role?.fg ?? Primer.fgDefault)
    }
}
