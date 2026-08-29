import Foundation
import SwiftUI
import AppKit

/// Single source of truth for the panel and the menu-bar glyph.
@MainActor
final class AppState: ObservableObject {

    // MARK: Polling intervals — see README "Why these intervals".
    // Defined in `PollingIntervals` so the cost projection, which is not main-actor bound,
    // can price a configuration without hopping actors.
    static let alarmInterval = PollingIntervals.alarm
    static let budgetInterval = PollingIntervals.budget
    static let metricsIntervalActive = PollingIntervals.metricsActive
    static let metricsIntervalIdle = PollingIntervals.metricsIdle
    static let metricsOpenThrottle = PollingIntervals.metricsOpenThrottle
    static let activeWindow = PollingIntervals.activeWindow

    /// One entry per watch target, each degrading independently of the others.
    @Published private(set) var cards: [TargetCard] = []
    @Published private(set) var cost = Loaded<CostBreakdown>()

    @Published private(set) var credentialSummary: String = "Not resolved"
    @Published private(set) var credentialError: String?
    @Published private(set) var isAsleep = false
    @Published private(set) var measuredSpend: Double = 0
    @Published private(set) var callCounts: [String: Int] = [:]
    @Published private(set) var meterSince: Date?
    @Published var launchAtLoginError: String?
    @Published private(set) var config: Configuration

    /// Ticks so relative timestamps ("2m ago") stay honest while the panel sits open.
    ///
    /// This lives here rather than in the view because `@State` is macro-backed in the
    /// macOS 27 SDK and its SwiftUIMacros plugin ships only with Xcode — see README
    /// "Building without Xcode". Every other SwiftUI property wrapper we use is a plain
    /// struct and works fine with Command Line Tools.
    @Published private(set) var now = Date()
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    private var ticker: Timer?

    private let meter: CallMeter
    let credentials = CredentialProvider()
    private let client: AWSClient

    private let cloudWatch: CloudWatchService
    private let budgets: BudgetsService
    private let costExplorer: CostExplorerService

    private var alarmPoller: Poller?
    private var budgetPoller: Poller?
    private var metricsPoller: Poller?

    private var lastPanelOpen: Date?
    private var lastMetricsFetch: Date?

    var health: Health { Health.evaluate(cards: cards, now: now) }

    /// What this configuration will cost per month, recomputed as targets change.
    var projection: CostProjection { CostProjection.estimate(targets: config.targets) }

    init() {
        let configuration = Configuration.load()
        self.config = configuration
        let meter = CallMeter(directory: DiskCache.directory)
        self.meter = meter
        let client = AWSClient(profileName: configuration.defaultProfile,
                               credentials: credentials, meter: meter)
        self.client = client
        self.cloudWatch = CloudWatchService(client: client)
        self.budgets = BudgetsService(client: client)
        self.costExplorer = CostExplorerService(client: client)

        self.cards = configuration.targets.map { TargetCard(target: $0) }
        restoreFromDisk()
        if !configuration.isConfigured {
            credentialError = Configuration.notConfiguredMessage
        }
        observeSleepWake()
        startPolling()
        startTicking()
        Task { await refreshMeter() }
    }

    private func startTicking() {
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = LaunchAtLogin.set(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: - Card access

    private func update(_ id: UUID, _ body: (inout Loaded<CardPayload>) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        body(&cards[index].state)
    }

    func card(_ id: UUID) -> TargetCard? { cards.first { $0.id == id } }

    /// Targets grouped by the credentials and endpoint they share. Everything that can be
    /// batched can only be batched inside one of these buckets.
    private func grouped(_ targets: [WatchTarget]) -> [[WatchTarget]] {
        Dictionary(grouping: targets) { "\($0.profile)|\($0.region)" }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    // MARK: - Lifecycle

    private func restoreFromDisk() {
        let cached = DiskCache.load()
        for index in cards.indices {
            if let saved = cached.cards[cards[index].id.uuidString] {
                cards[index].state = saved
            }
        }
        cost = cached.cost
    }

    private func persist() {
        var byID: [String: Loaded<CardPayload>] = [:]
        for card in cards { byID[card.id.uuidString] = card.state }
        DiskCache.save(CachedState(cards: byID, cost: cost))
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }

    private func suspend() {
        isAsleep = true
        ticker?.invalidate(); ticker = nil
        alarmPoller?.stop(); budgetPoller?.stop(); metricsPoller?.stop()
        alarmPoller = nil; budgetPoller = nil; metricsPoller = nil
    }

    private func resume() {
        isAsleep = false
        startPolling()
        startTicking()
    }

    private func startPolling() {
        let alarmPoller = Poller(name: "alarm", interval: { Self.alarmInterval }) { [weak self] in
            await self?.refreshAlarms() ?? false
        }
        let budgetPoller = Poller(name: "budget", interval: { Self.budgetInterval }) { [weak self] in
            await self?.refreshBudgets() ?? false
        }
        let metricsPoller = Poller(name: "metrics", interval: { [weak self] in
            guard let self else { return Self.metricsIntervalIdle }
            let recentlyUsed = self.lastPanelOpen.map {
                Date().timeIntervalSince($0) < Self.activeWindow
            } ?? false
            return recentlyUsed ? Self.metricsIntervalActive : Self.metricsIntervalIdle
        }) { [weak self] in
            await self?.refreshMetrics() ?? false
        }
        self.alarmPoller = alarmPoller
        self.budgetPoller = budgetPoller
        self.metricsPoller = metricsPoller
        alarmPoller.start(); budgetPoller.start(); metricsPoller.start()
    }

    // MARK: - Panel events

    func panelOpened() {
        let now = Date()
        lastPanelOpen = now
        alarmPoller?.refreshNow()
        // Only pay for metrics if the cached copy is genuinely old.
        let age = lastMetricsFetch.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if age > Self.metricsOpenThrottle { metricsPoller?.refreshNow() }
    }

    func refreshAllNow() {
        alarmPoller?.refreshNow()
        budgetPoller?.refreshNow()
        metricsPoller?.refreshNow()
    }

    // MARK: - Refreshers (return true when every card in the pass succeeded)

    /// One DescribeAlarms per (profile, region), not one per alarm. Free either way, but a
    /// flat request count is what keeps twenty targets from looking like a retry storm.
    @discardableResult
    private func refreshAlarms() async -> Bool {
        let targets = cards.map(\.target).filter {
            if case .alarm = $0.kind { return true }; return false
        }
        guard !targets.isEmpty else { return true }
        for target in targets { update(target.id) { $0.isRefreshing = true } }

        var allSucceeded = true
        for bucket in grouped(targets) {
            guard let first = bucket.first else { continue }
            let names = bucket.compactMap { target -> String? in
                if case .alarm(let name) = target.kind { return name }; return nil
            }
            do {
                let found = try await cloudWatch.describeAlarms(
                    names: names, region: first.region, profile: first.profile)
                for target in bucket {
                    guard case .alarm(let name) = target.kind else { continue }
                    if let snapshot = found[name] {
                        update(target.id) { $0.succeeded(.alarm(snapshot)) }
                    } else {
                        // A name that came back absent is a configuration error, not a
                        // transient one, and must not silently keep showing the old state.
                        update(target.id) {
                            $0.failed(AWSError(code: "AlarmNotFound",
                                               message: "No alarm named “\(name)”"))
                        }
                        allSucceeded = false
                    }
                }
                await noteCredentialSuccess(profile: first.profile)
            } catch {
                for target in bucket { update(target.id) { $0.failed(error) } }
                noteCredentialFailure(error)
                allSucceeded = false
            }
        }
        persist()
        return allSucceeded
    }

    @discardableResult
    private func refreshBudgets() async -> Bool {
        let targets = cards.map(\.target).filter {
            if case .budget = $0.kind { return true }; return false
        }
        guard !targets.isEmpty else { return true }

        var allSucceeded = true
        for target in targets {
            guard case .budget(let accountId, let name) = target.kind else { continue }
            update(target.id) { $0.isRefreshing = true }
            do {
                let snapshot = try await budgets.describeBudget(
                    accountId: accountId, name: name, profile: target.profile)
                update(target.id) { $0.succeeded(.budget(snapshot)) }
            } catch {
                update(target.id) { $0.failed(error) }
                noteCredentialFailure(error)
                allSucceeded = false
            }
        }
        persist()
        return allSucceeded
    }

    /// The only billed poll. Batched and deduplicated per (profile, region) — see
    /// `CloudWatchService.fetchMetrics` for why that saves money and what does not.
    @discardableResult
    private func refreshMetrics() async -> Bool {
        let targets = cards.map(\.target).filter { $0.metricGroup != nil }
        guard !targets.isEmpty else { return true }
        for target in targets { update(target.id) { $0.isRefreshing = true } }

        var allSucceeded = true
        for bucket in grouped(targets) {
            guard let first = bucket.first else { continue }
            do {
                let snapshots = try await cloudWatch.fetchMetrics(
                    targets: bucket, region: first.region, profile: first.profile)
                for target in bucket {
                    if let snapshot = snapshots[target.id] {
                        update(target.id) { $0.succeeded(.metrics(snapshot)) }
                    } else {
                        update(target.id) { $0.isRefreshing = false }
                    }
                }
            } catch {
                for target in bucket { update(target.id) { $0.failed(error) } }
                noteCredentialFailure(error)
                allSucceeded = false
            }
        }
        lastMetricsFetch = Date()
        await refreshMeter()
        persist()
        return allSucceeded
    }

    /// Manual only — this is the call that costs $0.01.
    func fetchCostBreakdown() {
        Task {
            cost.isRefreshing = true
            do {
                let breakdown = try await costExplorer.monthToDateByService(
                    profile: config.defaultProfile)
                cost.succeeded(breakdown)
            } catch {
                cost.failed(error)
            }
            await refreshMeter()
            persist()
        }
    }

    var costCacheIsFresh: Bool {
        guard let at = cost.lastSuccess else { return false }
        return Date().timeIntervalSince(at) < CostExplorerService.cacheLifetime
    }

    // MARK: - Credentials & metering

    private func noteCredentialSuccess(profile: String) async {
        credentialError = nil
        if let resolution = await client.resolution(for: profile) {
            credentialSummary = resolution.description
        }
    }

    private func noteCredentialFailure(_ error: Error) {
        if let awsError = error as? AWSError, awsError.isPermissionProblem {
            credentialError = awsError.localizedDescription
        } else if error is CredentialProvider.Failure {
            credentialError = error.localizedDescription
        }
    }

    private func refreshMeter() async {
        let tally = await meter.snapshot()
        measuredSpend = await meter.costToDate()
        callCounts = tally.calls
        meterSince = tally.since
    }

    func resetMeter() {
        Task { await meter.reset(); await refreshMeter() }
    }

    // MARK: - Connection test

    /// Runs one target's real call and reports what AWS said.
    ///
    /// Deliberately the same code path the poller uses, not a simplified stand-in: a test
    /// that passes while the poller fails would be worse than no test. Metric targets are
    /// billed here exactly as they are when polled, which is why the button states the count.
    func test(_ target: WatchTarget) async -> Result<String, Error> {
        do {
            switch target.kind {
            case .alarm(let name):
                let found = try await cloudWatch.describeAlarms(
                    names: [name], region: target.region, profile: target.profile)
                guard let snapshot = found[name] else {
                    throw AWSError(code: "AlarmNotFound",
                                   message: "No alarm named “\(name)” in \(target.region)")
                }
                await noteCredentialSuccess(profile: target.profile)
                return .success("Alarm reachable — currently \(snapshot.state).")

            case .budget(let accountId, let name):
                let snapshot = try await budgets.describeBudget(
                    accountId: accountId, name: name, profile: target.profile)
                await noteCredentialSuccess(profile: target.profile)
                return .success(String(format: "Budget reachable — $%.2f of $%.2f %@.",
                                       snapshot.actual, snapshot.limit, snapshot.unit))

            case .metricGroup(let group):
                let snapshots = try await cloudWatch.fetchMetrics(
                    targets: [target], region: target.region, profile: target.profile)
                await refreshMeter()
                guard let snapshot = snapshots[target.id] else {
                    throw AWSError(code: "NoData", message: "CloudWatch returned nothing")
                }
                let points = snapshot.series.reduce(0) { $0 + $1.points.count }
                await noteCredentialSuccess(profile: target.profile)
                if points == 0 {
                    // Not an error: a real metric with no traffic reports nothing. Saying so
                    // beats a green tick that implies data the card will render as "—".
                    return .success("Reachable, but CloudWatch has no datapoints for these "
                                    + "dimensions in the last \(Int(group.windowHours))h. "
                                    + "Check the dimension values if you expected traffic.")
                }
                return .success("Metrics reachable — \(points) datapoints across "
                                + "\(group.usedSeries.count) series.")
            }
        } catch {
            noteCredentialFailure(error)
            return .failure(error)
        }
    }

    // MARK: - Configuration

    /// Applies an edited configuration, keeping the live state of every target that survived.
    ///
    /// Surviving a config change matters: re-fetching everything because one card's name was
    /// corrected would blank the panel and, for metric cards, cost money to refill.
    func applyConfiguration(_ new: Configuration) {
        let previous = Dictionary(cards.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        config = new
        new.save()
        cards = new.targets.map { target in
            var card = TargetCard(target: target)
            if let kept = previous[target.id] { card.state = kept }
            return card
        }
        if new.isConfigured, credentialError == Configuration.notConfiguredMessage {
            credentialError = nil
        } else if !new.isConfigured {
            credentialError = Configuration.notConfiguredMessage
        }
        persist()
        Task {
            await client.setDefaultProfile(new.defaultProfile)
            await credentials.invalidate()
            refreshAllNow()
        }
    }
}
