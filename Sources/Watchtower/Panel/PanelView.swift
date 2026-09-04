import SwiftUI

/// The panel, laid out in GitHub's Primer design system.
///
/// Each section is a Primer `Box` — a bordered card with a `canvas.subtle` header — so the
/// panel reads as a stack of GitHub cards rather than a run of dividers. Colour is never
/// decorative here: it always carries a Primer role, and a degraded or failed reading is a
/// `flash` rather than a differently-tinted number.
struct PanelView: View {
    @EnvironmentObject var state: AppState

    /// Relative timestamps redraw from the model's clock. See AppState.now for why this is
    /// not `@State`.
    private var tick: Date { state.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            alarmSection
            cloudFrontSection
            budgetSection
            costSection
            PrimerRule()
            footer
        }
        .padding(12)
        .frame(width: 348)
        .background(Primer.canvasDefault)
        .onAppear { state.panelOpened() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: state.health.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(state.health.role.fg)
                Text("ryangrey.dev")
                    .font(Primer.title)
                    .foregroundStyle(Primer.fgDefault)
                PrimerLabel(text: state.health.labelText,
                            role: state.health.role,
                            filled: state.health.isWarning)
                Spacer(minLength: 4)
                Button {
                    state.refreshAllNow()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PrimerInvisibleButtonStyle())
                .help("Refresh now")
            }

            if !state.health.isOK {
                Text(state.health.summary)
                    .font(Primer.small)
                    .foregroundStyle(Primer.fgMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Alarm

    private var alarmSection: some View {
        PrimerBox("Alarm",
                  icon: "bell",
                  trailing: Fmt.relative(state.alarm.lastSuccess, asOf: tick)) {
            if let value = state.alarm.value {
                HStack(spacing: 7) {
                    PrimerLabel(text: value.state,
                                role: alarmRole(value.state),
                                filled: value.state == "ALARM",
                                icon: alarmIcon(value.state))
                    Spacer(minLength: 6)
                    if let updated = value.stateUpdated {
                        Text("since \(Fmt.relative(updated, asOf: tick))")
                            .font(Primer.caption)
                            .foregroundStyle(Primer.fgMuted)
                    }
                }
                Text(value.name)
                    .font(Primer.mono(10))
                    .foregroundStyle(Primer.fgSubtle)
                    .lineLimit(1)
            }
            if state.alarm.isFailing, let message = state.alarm.errorText {
                FailureNote(message: message, lastSuccess: state.alarm.lastSuccess)
            } else if state.alarm.value == nil {
                WaitingNote()
            }
        }
    }

    private func alarmRole(_ state: String) -> PrimerRole {
        switch state {
        case "OK":    return .success
        case "ALARM": return .danger
        default:      return .attention
        }
    }

    private func alarmIcon(_ state: String) -> String {
        switch state {
        case "OK":    return "checkmark"
        case "ALARM": return "exclamationmark.triangle.fill"
        default:      return "questionmark"
        }
    }

    // MARK: CloudFront

    private var cloudFrontSection: some View {
        PrimerBox("CloudFront",
                  icon: "chart.bar",
                  trailing: Fmt.relative(state.metrics.lastSuccess, asOf: tick)) {
            if let value = state.metrics.value {
                MetricGrid(snapshot: value)
            }
            if state.metrics.isFailing, let message = state.metrics.errorText {
                FailureNote(message: message, lastSuccess: state.metrics.lastSuccess)
            } else if state.metrics.value == nil {
                WaitingNote()
            }
        }
    }

    // MARK: Budget

    private var budgetSection: some View {
        PrimerBox("Month to date",
                  icon: "creditcard",
                  trailing: Fmt.relative(state.budget.lastSuccess, asOf: tick)) {
            if let value = state.budget.value {
                BudgetBar(snapshot: value)
                if let updated = value.lastUpdated {
                    Text("AWS recalculated \(Fmt.relative(updated, asOf: tick))")
                        .font(Primer.caption)
                        .foregroundStyle(Primer.fgSubtle)
                }
            }
            if state.budget.isFailing, let message = state.budget.errorText {
                FailureNote(message: message, lastSuccess: state.budget.lastSuccess)
            } else if state.budget.value == nil {
                WaitingNote()
            }
        }
    }

    // MARK: Cost Explorer (manual, billed)

    private var costSection: some View {
        PrimerBox("Spend breakdown",
                  icon: "list.bullet.rectangle",
                  trailing: state.cost.lastSuccess == nil
                    ? nil : "cached \(Fmt.relative(state.cost.lastSuccess, asOf: tick))") {

            if let value = state.cost.value {
                if value.looksUnpopulated {
                    // The trap this app exists to avoid: CE returns structurally valid,
                    // all-zero data while backfilling. Showing "$0.00" here would be a lie.
                    PrimerFlash(role: .attention, icon: "clock.badge.exclamationmark") {
                        Text("Cost Explorer has data for only \(value.populatedDays) of \(value.totalDays) days — still backfilling.")
                            .font(Primer.small)
                            .foregroundStyle(Primer.fgDefault)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("This is not a $0 month.")
                            .font(Primer.caption)
                            .foregroundStyle(Primer.fgMuted)
                    }
                } else if value.services.isEmpty {
                    Text("No service-level costs returned for \(value.periodStart) → \(value.periodEnd).")
                        .font(Primer.small)
                        .foregroundStyle(Primer.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(value.services.prefix(5)), id: \.name) { service in
                            costRow(service.name,
                                    Fmt.money(service.amount, places: 4),
                                    emphasised: false)
                            PrimerRule()
                        }
                        costRow("Total", Fmt.money(value.total, places: 4), emphasised: true)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Primer.radius, style: .continuous)
                            .strokeBorder(Primer.borderDefault, lineWidth: Primer.borderWidth)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Primer.radius, style: .continuous))
                }
            }

            if state.cost.isFailing, let message = state.cost.errorText {
                FailureNote(message: message, lastSuccess: state.cost.lastSuccess)
            }

            HStack(spacing: 7) {
                Button {
                    state.fetchCostBreakdown()
                } label: {
                    HStack(spacing: 5) {
                        if state.cost.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "dollarsign.magnifyingglass")
                                .font(.system(size: 10))
                        }
                        Text(state.cost.value == nil ? "Break down spend" : "Refresh breakdown")
                    }
                }
                .buttonStyle(PrimerButtonStyle())
                .disabled(state.cost.isRefreshing)
                .help("Cost Explorer bills about $0.01 per request. This never runs on a timer.")

                PrimerCounter(text: "$0.01")
                Spacer(minLength: 0)
            }

            if state.costCacheIsFresh {
                Text("Cached result is under 24h old — no need to pay again.")
                    .font(Primer.caption)
                    .foregroundStyle(Primer.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func costRow(_ name: String, _ amount: String, emphasised: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(emphasised ? Primer.text(11, .semibold) : Primer.small)
                .foregroundStyle(Primer.fgDefault)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(amount)
                .font(Primer.mono(11, emphasised ? .semibold : .regular))
                .foregroundStyle(emphasised ? Primer.fgDefault : Primer.fgMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(emphasised ? Primer.canvasSubtle : Primer.canvasDefault)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            PrimerRow(label: state.credentialSummary) {
                Text(state.config.region)
                    .font(Primer.mono(10))
                    .foregroundStyle(Primer.fgSubtle)
            }

            if let credentialError = state.credentialError {
                PrimerFlash(role: .attention, icon: "key.slash") {
                    Text(credentialError)
                        .font(Primer.caption)
                        .foregroundStyle(Primer.fgDefault)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrimerRow(label: "Measured API spend") {
                Text(Fmt.money(state.measuredSpend, places: 4))
                    .font(Primer.mono(10))
                    .foregroundStyle(Primer.fgDefault)
            }

            if let since = state.meterSince {
                Text("since \(Fmt.relative(since, asOf: tick)) · "
                     + state.callCounts.sorted { $0.key < $1.key }
                        .map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                    .font(Primer.text(9))
                    .foregroundStyle(Primer.fgSubtle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.isAsleep {
                PrimerLabel(text: "Polling suspended — machine asleep",
                            role: .neutral,
                            icon: "moon.zzz")
            }

            HStack {
                Toggle(isOn: Binding(get: { state.launchAtLogin },
                                     set: { state.setLaunchAtLogin($0) })) {
                    Text("Launch at login")
                        .font(Primer.small)
                        .foregroundStyle(Primer.fgDefault)
                }
                .toggleStyle(.checkbox)
                .disabled(!LaunchAtLogin.isAvailable)

                Spacer(minLength: 8)

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(PrimerInvisibleButtonStyle(role: .danger))
            }

            if let error = state.launchAtLoginError {
                Text(error)
                    .font(Primer.caption)
                    .foregroundStyle(Primer.attentionFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
