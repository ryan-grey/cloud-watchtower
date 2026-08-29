import SwiftUI

struct PanelView: View {
    @EnvironmentObject var state: AppState

    /// Relative timestamps redraw from the model's clock. See AppState.now for why this is
    /// not `@State`.
    private var tick: Date { state.now }

    /// Cards keep their configured order inside a section, and sections keep a fixed order,
    /// so adding a target never reshuffles the panel under the user.
    private var sections: [(title: String, cards: [TargetCard])] {
        var order: [String] = []
        var byTitle: [String: [TargetCard]] = [:]
        for card in state.cards {
            let title = card.target.sectionTitle
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(card)
        }
        let rank = ["Alarm": 0, "Budget": 1]
        return order
            .sorted { (rank[$0] ?? 2, $0) < (rank[$1] ?? 2, $1) }
            .map { ($0, byTitle[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if state.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: section.title,
                                              trailing: section.cards.count > 1
                                                ? "\(section.cards.count)" : nil)
                                ForEach(section.cards) { card in
                                    CardView(card: card, now: tick)
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(.trailing, 2)
                }
                // Enough for roughly four cards; beyond that the panel scrolls rather than
                // growing past the screen. The menu-bar popover has no scroll of its own.
                .frame(maxHeight: 420)
            }

            costSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { state.panelOpened() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: state.health.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(state.health.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Watchtower")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.health.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { state.refreshAllNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            Button { SettingsWindow.show(state: state) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing is being watched yet.")
                .font(.system(size: 12, weight: .medium))
            Text("Add an alarm, a budget or a metric card in Settings. "
                 + "The panel shows what each one costs before you commit to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…") { SettingsWindow.show(state: state) }
                .font(.system(size: 11))
        }
        .padding(.vertical, 4)
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
                Text(state.config.defaultRegion)
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
            HStack {
                Text("Projected")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(Fmt.money(state.projection.monthlyMetricCost, places: 2))/mo · \(state.projection.uniqueMetrics) metrics")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
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

/// One watch target, rendered according to what it holds.
///
/// Every branch keeps the same contract the single-target panel had: a value is shown with
/// its age, a failure is named alongside the age of the last good value, and a card that has
/// never loaded says so rather than showing zeros.
struct CardView: View {
    let card: TargetCard
    let now: Date

    private var state: Loaded<CardPayload> { card.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.target.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.relative(state.lastSuccess, asOf: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if let payload = state.value {
                switch payload {
                case .alarm(let alarm):   alarmBody(alarm)
                case .budget(let budget): BudgetBar(snapshot: budget)
                case .metrics(let snapshot):
                    if let group = card.target.metricGroup {
                        MetricGrid(group: group, snapshot: snapshot, now: now)
                    }
                }
            }

            if state.isFailing, let message = state.errorText {
                FailureNote(message: message, lastSuccess: state.lastSuccess)
            } else if state.value == nil {
                Text("Waiting for first refresh…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if state.isStale(asOf: now) {
                // A value old enough to stop counting as evidence of health says so on the
                // card too, not just in the glyph.
                Text("Older than \(Int(Health.staleAfter / 60)) minutes — not current.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func alarmBody(_ alarm: AlarmSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(color(alarm.state)).frame(width: 8, height: 8)
                Text(alarm.state).font(.system(size: 12, weight: .medium))
                Spacer()
                if let updated = alarm.stateUpdated {
                    Text("since \(Fmt.relative(updated, asOf: now))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !alarm.reason.isEmpty {
                Text(alarm.reason)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ value: String) -> Color {
        switch value {
        case "OK": return .green
        case "ALARM": return .red
        default: return .orange
        }
    }
}
