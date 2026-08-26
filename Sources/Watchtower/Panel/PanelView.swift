import SwiftUI

struct PanelView: View {
    @EnvironmentObject var state: AppState

    /// Relative timestamps redraw from the model's clock. See AppState.now for why this is
    /// not `@State`.
    private var tick: Date { state.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            alarmSection
            Divider()
            cloudFrontSection
            Divider()
            budgetSection
            Divider()
            costSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { state.panelOpened() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: state.health.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(state.health.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("ryangrey.dev")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.health.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                state.refreshAllNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    // MARK: Alarm

    private var alarmSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Alarm", trailing: Fmt.relative(state.alarm.lastSuccess, asOf: tick))
            if let value = state.alarm.value {
                HStack(spacing: 7) {
                    Circle()
                        .fill(alarmColor(value.state))
                        .frame(width: 8, height: 8)
                    Text(value.state)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let updated = value.stateUpdated {
                        Text("since \(Fmt.relative(updated, asOf: tick))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(value.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if state.alarm.isFailing, let message = state.alarm.errorText {
                FailureNote(message: message, lastSuccess: state.alarm.lastSuccess)
            } else if state.alarm.value == nil {
                Text("Waiting for first refresh…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func alarmColor(_ state: String) -> Color {
        switch state {
        case "OK": return .green
        case "ALARM": return .red
        default: return .orange
        }
    }

    // MARK: CloudFront

    private var cloudFrontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "CloudFront",
                          trailing: Fmt.relative(state.metrics.lastSuccess, asOf: tick))
            if let value = state.metrics.value {
                MetricGrid(snapshot: value)
            }
            if state.metrics.isFailing, let message = state.metrics.errorText {
                FailureNote(message: message, lastSuccess: state.metrics.lastSuccess)
            } else if state.metrics.value == nil {
                Text("Waiting for first refresh…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Budget

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Month to date",
                          trailing: Fmt.relative(state.budget.lastSuccess, asOf: tick))
            if let value = state.budget.value {
                BudgetBar(snapshot: value)
                if let updated = value.lastUpdated {
                    Text("AWS recalculated \(Fmt.relative(updated, asOf: tick))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            if state.budget.isFailing, let message = state.budget.errorText {
                FailureNote(message: message, lastSuccess: state.budget.lastSuccess)
            } else if state.budget.value == nil {
                Text("Waiting for first refresh…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cost Explorer (manual, billed)

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Spend breakdown",
                          trailing: state.cost.lastSuccess == nil
                            ? nil : "cached \(Fmt.relative(state.cost.lastSuccess, asOf: tick))")

            if let value = state.cost.value {
                if value.looksUnpopulated {
                    // The trap this app exists to avoid: CE returns structurally valid,
                    // all-zero data while backfilling. Showing "$0.00" here would be a lie.
                    Label("Cost Explorer has data for only \(value.populatedDays) of \(value.totalDays) days — still backfilling. Not a $0 month.",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if value.services.isEmpty {
                    Text("No service-level costs returned for \(value.periodStart) → \(value.periodEnd).")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(value.services.prefix(5), id: \.name) { service in
                        HStack {
                            Text(service.name)
                                .font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(Fmt.money(service.amount, places: 4))
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Total").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(Fmt.money(value.total, places: 4))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                }
            }

            if state.cost.isFailing, let message = state.cost.errorText {
                FailureNote(message: message, lastSuccess: state.cost.lastSuccess)
            }

            Button {
                state.fetchCostBreakdown()
            } label: {
                HStack(spacing: 5) {
                    if state.cost.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "dollarsign.magnifyingglass")
                    }
                    Text(state.cost.value == nil ? "Break down spend" : "Refresh breakdown")
                    Text("· $0.01").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(state.cost.isRefreshing)
            .help("Cost Explorer bills about $0.01 per request. This never runs on a timer.")

            if state.costCacheIsFresh {
                Text("Cached result is under 24h old — no need to pay again.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: state.credentialError == nil ? "key" : "key.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(state.credentialError == nil ? Color.secondary : Color.orange)
                Text(state.credentialSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(state.config.region)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let credentialError = state.credentialError {
                Text(credentialError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Measured API spend")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.money(state.measuredSpend, places: 4))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let since = state.meterSince {
                Text("since \(Fmt.relative(since, asOf: tick)) · "
                     + state.callCounts.sorted { $0.key < $1.key }
                        .map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.isAsleep {
                Label("Polling suspended (machine asleep)", systemImage: "moon.zzz")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Toggle(isOn: Binding(get: { state.launchAtLogin },
                                 set: { state.setLaunchAtLogin($0) })) {
                Text("Launch at login").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .disabled(!LaunchAtLogin.isAvailable)
            if let error = state.launchAtLoginError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
    }
}
