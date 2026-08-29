import SwiftUI
import AppKit

/// Add / edit / remove watch targets, with the bill for the current configuration visible
/// while it is being built.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        HSplitView {
            targetList.frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
            detail.frame(minWidth: 380)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: Left — the list

    private var targetList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { store.selection },
                                    set: { store.selection = $0 })) {
                ForEach(store.draft.targets) { target in
                    HStack(spacing: 7) {
                        Image(systemName: icon(target))
                            .font(.system(size: 11))
                            .foregroundStyle(target.isFree ? Color.secondary : Color.orange)
                            .help(target.isFree ? "Free to poll" : "Billed metric")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.displayName.isEmpty ? "Untitled" : target.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text("\(target.profile) · \(target.region)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(target.id)
                }
            }

            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("Alarm") { store.add(nil) }
                    Button("Budget") { store.addBudget() }
                    Divider()
                    ForEach(RecipeID.allCases, id: \.self) { recipe in
                        Button(recipe.displayName) { store.add(recipe) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)

                Button { store.removeSelected() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(store.selection == nil)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private func icon(_ target: WatchTarget) -> String {
        switch target.kind {
        case .alarm:        return "bell"
        case .budget:       return "dollarsign.circle"
        case .metricGroup:  return "chart.xyaxis.line"
        }
    }

    // MARK: Right — the editor

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let index = store.selectedIndex {
                    editor(index)
                } else {
                    Text("Select a target, or add one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                accountDefaults
                Divider()
                costPanel
                Spacer(minLength: 0)
                buttons
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func editor(_ index: Int) -> some View {
        let target = store.draft.targets[index]

        VStack(alignment: .leading, spacing: 12) {
            LabeledField("Name") {
                TextField("Display name", text: binding(index, \.displayName))
            }

            HStack(spacing: 12) {
                LabeledField("Profile") {
                    Picker("", selection: binding(index, \.profile)) {
                        ForEach(store.profiles, id: \.self) { Text($0).tag($0) }
                        if !store.profiles.contains(target.profile) {
                            Text(store.isMissing(target.profile)
                                 ? "\(target.profile) (not in ~/.aws)" : target.profile)
                                .tag(target.profile)
                        }
                    }
                    .labelsHidden()
                }
                LabeledField("Region") {
                    TextField("us-east-1", text: binding(index, \.region))
                        .disabled(forcedRegion(target) != nil)
                }
            }
            if let forced = forcedRegion(target) {
                Note("CloudFront publishes metrics only into \(forced), wherever the "
                     + "distribution serves from. Region is fixed for this card.")
            }

            switch target.kind {
            case .alarm:
                LabeledField("Alarm name") {
                    TextField("cloudfront-5xx-error-rate", text: alarmName(index))
                }
                Note("DescribeAlarms is inside the CloudWatch free tier, so this card polls "
                     + "every \(Int(AppState.alarmInterval))s and is allowed to drive the "
                     + "menu-bar glyph.")

            case .budget:
                HStack(spacing: 12) {
                    LabeledField("Account ID") {
                        TextField("123456789012", text: budgetAccount(index))
                    }
                    LabeledField("Budget name") {
                        TextField("monthly-budget", text: budgetName(index))
                    }
                }
                Note("DescribeBudget is not charged. AWS recalculates spend about three "
                     + "times a day, so this polls every \(Int(AppState.budgetInterval / 60)) "
                     + "minutes — faster would buy nothing.")

            case .metricGroup(let group):
                LabeledField("Source") {
                    Picker("", selection: Binding(
                        get: { group.recipe },
                        set: { store.changeRecipe(at: index, to: $0) })) {
                        ForEach(RecipeID.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                }

                if group.recipe == .custom {
                    LabeledField("Namespace") {
                        TextField("AWS/SQS", text: customNamespace(index))
                    }
                    LabeledField("Metric name") {
                        TextField("ApproximateNumberOfMessagesVisible",
                                  text: customMetric(index))
                    }
                } else {
                    ForEach(group.recipe.dimensionKeys, id: \.self) { key in
                        LabeledField(key) {
                            TextField(placeholder(key), text: dimension(index, key))
                        }
                    }
                }

                if !group.usedSeries.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Requests \(group.usedSeries.count) metrics per poll: "
                             + group.usedSeries.map(\.metricName).joined(separator: ", "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Shows: " + group.derived.map(\.label).joined(separator: ", "))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Note("GetMetricData is billed per metric requested. This card adds "
                     + "\(group.usedSeries.count) metrics to every poll.")
            }

            testRow(target)
        }
    }

    private func testRow(_ target: WatchTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    store.testSelected()
                } label: {
                    HStack(spacing: 5) {
                        if store.isTesting { ProgressView().controlSize(.small) }
                        Text("Test connection")
                    }
                }
                .disabled(store.isTesting)

                // The Cost Explorer button states its own price; anything else that spends
                // money should too, however small the amount.
                Text(target.isFree
                     ? "· free"
                     : "· \(target.metricGroup?.usedSeries.count ?? 0) billed metrics")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if let message = store.testMessage {
                Label(message, systemImage: store.testSucceeded
                      ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(store.testSucceeded ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountDefaults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEFAULTS FOR NEW TARGETS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).kerning(0.6)
            HStack(spacing: 12) {
                LabeledField("Profile") {
                    Picker("", selection: Binding(get: { store.draft.defaultProfile },
                                                  set: { store.draft.defaultProfile = $0 })) {
                        ForEach(store.profiles, id: \.self) { Text($0).tag($0) }
                        if !store.profiles.contains(store.draft.defaultProfile) {
                            Text(store.isMissing(store.draft.defaultProfile)
                                 ? "\(store.draft.defaultProfile) (not in ~/.aws)"
                                 : store.draft.defaultProfile)
                                .tag(store.draft.defaultProfile)
                        }
                    }
                    .labelsHidden()
                }
                LabeledField("Region") {
                    TextField("us-east-1", text: Binding(get: { store.draft.defaultRegion },
                                                         set: { store.draft.defaultRegion = $0 }))
                }
                LabeledField("Account ID") {
                    TextField("123456789012",
                              text: Binding(get: { store.draft.defaultAccountId },
                                            set: { store.draft.defaultAccountId = $0 }))
                }
            }
            Note("AWS_PROFILE and AWS_REGION are deliberately ignored: an app launched at "
                 + "login inherits no shell environment, so honouring them would work from a "
                 + "terminal and fail silently at login.")
        }
    }

    /// The bill for the configuration currently on screen, not the one already saved.
    private var costPanel: some View {
        let projection = store.projection
        return VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THIS CONFIGURATION COSTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).kerning(0.6)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.money(projection.monthlyMetricCost, places: 2))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("/ month")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }

            Text(projection.summary)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let duplicates = projection.duplicateNote {
                Note(duplicates)
            }
            Note("Billing is per metric requested, not per request — batching queries into "
                 + "one call does not reduce this. Fewer series and a slower cadence do. "
                 + "The Cost Explorer button is separate and always manual, at $0.01 a press.")
        }
    }

    private var buttons: some View {
        HStack {
            if store.isDirty {
                Text("Unsaved changes")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            Button("Revert") { store.revert() }.disabled(!store.isDirty)
            Button("Apply") { store.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.isDirty)
        }
    }

    // MARK: Bindings into the draft

    private func binding(_ index: Int,
                         _ path: WritableKeyPath<WatchTarget, String>) -> Binding<String> {
        Binding(get: { store.draft.targets[index][keyPath: path] },
                set: { store.draft.targets[index][keyPath: path] = $0 })
    }

    private func alarmName(_ index: Int) -> Binding<String> {
        Binding(get: {
            if case .alarm(let name) = store.draft.targets[index].kind { return name }
            return ""
        }, set: { store.draft.targets[index].kind = .alarm(name: $0) })
    }

    private func budgetAccount(_ index: Int) -> Binding<String> {
        Binding(get: {
            if case .budget(let account, _) = store.draft.targets[index].kind { return account }
            return ""
        }, set: {
            guard case .budget(_, let name) = store.draft.targets[index].kind else { return }
            store.draft.targets[index].kind = .budget(accountId: $0, name: name)
        })
    }

    private func budgetName(_ index: Int) -> Binding<String> {
        Binding(get: {
            if case .budget(_, let name) = store.draft.targets[index].kind { return name }
            return ""
        }, set: {
            guard case .budget(let account, _) = store.draft.targets[index].kind else { return }
            store.draft.targets[index].kind = .budget(accountId: account, name: $0)
        })
    }

    private func dimension(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { store.draft.targets[index].metricGroup?.dimensions[key] ?? "" },
                set: { newValue in
            guard var group = store.draft.targets[index].metricGroup else { return }
            group.dimensions[key] = newValue
            store.draft.targets[index].kind = .metricGroup(group)
        })
    }

    private func customNamespace(_ index: Int) -> Binding<String> {
        Binding(get: { store.draft.targets[index].metricGroup?.namespace ?? "" },
                set: { newValue in
            guard var group = store.draft.targets[index].metricGroup else { return }
            group.namespace = newValue
            store.draft.targets[index].kind = .metricGroup(group)
        })
    }

    private func customMetric(_ index: Int) -> Binding<String> {
        Binding(get: { store.draft.targets[index].metricGroup?.series.first?.metricName ?? "" },
                set: { newValue in
            guard var group = store.draft.targets[index].metricGroup,
                  !group.series.isEmpty else { return }
            group.series[0].metricName = newValue
            store.draft.targets[index].kind = .metricGroup(group)
        })
    }

    private func forcedRegion(_ target: WatchTarget) -> String? {
        target.metricGroup?.recipe.forcedRegion
    }

    private func placeholder(_ key: String) -> String {
        switch key {
        case "DistributionId": return "EXXXXXXXXXXXXX"
        case "FunctionName":   return "my-function"
        case "ApiName":        return "my-api"
        case "TableName":      return "my-table"
        default:               return key
        }
    }
}

/// A label above its control. Keeps the editor's rows aligned without a Form, which on
/// macOS 13 styles inconsistently between a window and a sheet.
struct LabeledField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}

/// Explanatory small print. Used for the reasoning behind a polling decision, which is the
/// product, not decoration.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain NSWindow rather than SwiftUI's `Settings` scene.
///
/// `Settings` needs `showSettingsWindow:` on macOS 14 and `showPreferencesWindow:` on 13, and
/// neither selector is reachable from a `MenuBarExtra`-only app without version-specific
/// glue. Hosting the view directly works identically on both.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var store: SettingsStore?

    static func show(state: AppState) {
        if let window, let store {
            store.revert()          // reopen on the live config, not a stale draft
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let store = SettingsStore(state: state)
        let view = NSHostingView(rootView: SettingsView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Watchtower Settings"
        window.contentView = view
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.store = store
        self.window = window
    }

    /// Draw the settings window straight to a PNG, no screen involved — the same trick
    /// `--render` uses for the panel, and the only way to check this window in CI or on a
    /// headless build machine.
    static func render(state: AppState, to path: String, scale: Int = 2) {
        let store = SettingsStore(state: state)
        // Read ~/.aws before drawing, or the picker is captured mid-load.
        Task { @MainActor in
            await store.loadProfiles()
            draw(store, to: path, scale: scale)
        }
    }

    private static func draw(_ store: SettingsStore, to path: String, scale: Int) {
        let size = NSSize(width: 760, height: 620)
        // Wrapped in a plain NSView and cached from *that*, exactly as PreviewWindow does.
        // Calling cacheDisplay on an NSHostingView directly captured only its AppKit-backed
        // controls — the text fields drew and every SwiftUI-drawn label and picker came out
        // blank.
        let root = SettingsView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = false
        container.addSubview(view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("render-settings: no bitmap\n".utf8))
            exit(1)
        }
        rep.size = size
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            FileHandle.standardError.write(Data("render-settings: could not write\n".utf8))
            exit(1)
        }
        FileHandle.standardError.write(Data("rendered settings to \(path)\n".utf8))
        exit(0)
    }
}
