import Foundation
import SwiftUI
import AppKit

/// Single source of truth for the panel and the menu-bar glyph.
@MainActor
final class AppState: ObservableObject {

    // MARK: Polling intervals — see README "Why these intervals"
    /// Free (DescribeAlarms). Drives the glyph, so it runs fastest.
    static let alarmInterval: TimeInterval = 60
    /// Free (DescribeBudget). AWS recalculates spend ~3×/day; 10 minutes is already generous.
    static let budgetInterval: TimeInterval = 600
    /// Billed. 5 minutes while the panel is in use...
    static let metricsIntervalActive: TimeInterval = 300
    /// ...15 minutes otherwise. The glyph never depends on this, so it can afford to be slow.
    static let metricsIntervalIdle: TimeInterval = 900
    /// A panel reopened within a minute reuses what is on screen rather than paying again.
    static let metricsOpenThrottle: TimeInterval = 60
    /// Billed, but barely: ~21 metrics per call at $0.01 per 1,000 is about two hundredths of
    /// a cent a poll. AWS itself only republishes billing data every few hours, so this is far
    /// faster than the underlying source changes — it buys promptness after a refresh, not
    /// resolution. Overridable via `billingIntervalSeconds`. See README "Why these intervals".
    static let billingIntervalDefault: TimeInterval = 900
    /// How long after the panel closes we keep treating the app as "in use".
    static let activeWindow: TimeInterval = 600

    @Published private(set) var alarm = Loaded<AlarmSnapshot>()
    @Published private(set) var budget = Loaded<BudgetSnapshot>()
    @Published private(set) var metrics = Loaded<MetricsSnapshot>()
    @Published private(set) var cost = Loaded<CostBreakdown>()
    @Published private(set) var billing = Loaded<BillingSnapshot>()
    /// True once we have confirmed the AWS/Billing namespace is empty, which means billing
    /// alerts have never been switched on. Kept separate from a failure: there is nothing
    /// wrong, there is just nothing to read yet.
    @Published private(set) var billingNotEnabled = false

    @Published private(set) var credentialSummary: String = "Not resolved"
    @Published private(set) var credentialError: String?
    @Published private(set) var isAsleep = false
    @Published private(set) var measuredSpend: Double = 0
    @Published private(set) var callCounts: [String: Int] = [:]
    @Published private(set) var meterSince: Date?
    @Published var launchAtLoginError: String?
    /// Lives here rather than as view `@State` for the same SDK reason `now` does.
    @Published var expandBillingServices = false
    @Published var config: Configuration

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
    private let credentials = CredentialProvider()
    private let client: AWSClient

    private var cloudWatch: CloudWatchService
    private var budgets: BudgetsService
    private var costExplorer: CostExplorerService
    private let billingService: BillingService

    private var alarmPoller: Poller?
    private var budgetPoller: Poller?
    private var metricsPoller: Poller?
    private var billingPoller: Poller?

    private var lastPanelOpen: Date?
    private var lastMetricsFetch: Date?
    /// Discovered once, then reused. New services appear in a billing account rarely, and
    /// re-listing on every poll would be a wasted round trip; a failed fetch clears it so the
    /// next poll rediscovers.
    private var billingServices: [String] = []

    var health: Health { Health.evaluate(alarm: alarm, budget: budget) }

    init() {
        let configuration = Configuration.load()
        self.config = configuration
        let meter = CallMeter(directory: DiskCache.directory)
        self.meter = meter
        let client = AWSClient(profileName: configuration.profileName,
                               credentials: credentials, meter: meter)
        self.client = client
        self.cloudWatch = CloudWatchService(client: client, config: configuration)
        self.budgets = BudgetsService(client: client, config: configuration)
        self.costExplorer = CostExplorerService(client: client, config: configuration)
        // No config dependency: AWS/Billing is account-wide and us-east-1 only.
        self.billingService = BillingService(client: client)

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

    // MARK: - Lifecycle

    private func restoreFromDisk() {
        let cached = DiskCache.load()
        if let value = cached.alarm { alarm.value = value; alarm.lastSuccess = cached.alarmAt }
        if let value = cached.budget { budget.value = value; budget.lastSuccess = cached.budgetAt }
        if let value = cached.metrics { metrics.value = value; metrics.lastSuccess = cached.metricsAt }
        if let value = cached.cost { cost.value = value; cost.lastSuccess = cached.costAt }
        if let value = cached.billing { billing.value = value; billing.lastSuccess = cached.billingAt }
        billingServices = cached.billingServices ?? []
    }

    private func persist() {
        DiskCache.save(CachedState(
            alarm: alarm.value, alarmAt: alarm.lastSuccess,
            budget: budget.value, budgetAt: budget.lastSuccess,
            metrics: metrics.value, metricsAt: metrics.lastSuccess,
            cost: cost.value, costAt: cost.lastSuccess,
            billing: billing.value, billingAt: billing.lastSuccess,
            billingServices: billingServices.isEmpty ? nil : billingServices))
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
        alarmPoller?.stop(); budgetPoller?.stop(); metricsPoller?.stop(); billingPoller?.stop()
        alarmPoller = nil; budgetPoller = nil; metricsPoller = nil; billingPoller = nil
    }

    private func resume() {
        isAsleep = false
        startPolling()
        startTicking()
    }

    private func startPolling() {
        let alarmPoller = Poller(name: "alarm", interval: { Self.alarmInterval }) { [weak self] in
            await self?.refreshAlarm() ?? false
        }
        let budgetPoller = Poller(name: "budget", interval: { Self.budgetInterval }) { [weak self] in
            await self?.refreshBudget() ?? false
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
        let billingPoller = Poller(name: "billing", interval: { [weak self] in
            self?.config.billingIntervalSeconds ?? Self.billingIntervalDefault
        }) { [weak self] in
            await self?.refreshBilling() ?? false
        }
        self.alarmPoller = alarmPoller
        self.budgetPoller = budgetPoller
        self.metricsPoller = metricsPoller
        self.billingPoller = billingPoller
        alarmPoller.start(); budgetPoller.start(); metricsPoller.start(); billingPoller.start()
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
        billingPoller?.refreshNow()
    }

    // MARK: - Refreshers (return true on success)

    @discardableResult
    private func refreshAlarm() async -> Bool {
        alarm.isRefreshing = true
        do {
            let snapshot = try await cloudWatch.describeAlarm()
            alarm.succeeded(snapshot)
            await noteCredentialSuccess()
            persist(); return true
        } catch {
            alarm.failed(error)
            noteCredentialFailure(error)
            persist(); return false
        }
    }

    @discardableResult
    private func refreshBudget() async -> Bool {
        budget.isRefreshing = true
        do {
            let snapshot = try await budgets.describeBudget()
            budget.succeeded(snapshot)
            persist(); return true
        } catch {
            budget.failed(error)
            noteCredentialFailure(error)
            persist(); return false
        }
    }

    @discardableResult
    private func refreshMetrics() async -> Bool {
        metrics.isRefreshing = true
        do {
            let snapshot = try await cloudWatch.getMetricData()
            metrics.succeeded(snapshot)
            lastMetricsFetch = Date()
            await refreshMeter()
            persist(); return true
        } catch {
            metrics.failed(error)
            noteCredentialFailure(error)
            await refreshMeter()
            persist(); return false
        }
    }

    @discardableResult
    private func refreshBilling() async -> Bool {
        billing.isRefreshing = true
        do {
            // The service list is discovered once and reused; ListMetrics is free, so the
            // only cost of rediscovering is a round trip.
            if billingServices.isEmpty {
                switch try await billingService.availability() {
                case .notEnabled:
                    // Not a failure. There is no metric to read because the account has never
                    // been asked to publish one, and saying so is more useful than a $0.00.
                    billingNotEnabled = true
                    billing.isRefreshing = false
                    return true
                case .enabled(let services):
                    billingNotEnabled = false
                    billingServices = services
                }
            }

            let snapshot = try await billingService.currentCharges(services: billingServices)
            billing.succeeded(snapshot)
            billingNotEnabled = false
            await refreshMeter()
            persist(); return true
        } catch {
            billing.failed(error)
            // Force rediscovery next time: a stale service list is a plausible cause of a
            // failure here, and it is free to rebuild.
            billingServices = []
            noteCredentialFailure(error)
            await refreshMeter()
            persist(); return false
        }
    }

    /// What one billing poll costs, so the panel can state it rather than estimate it.
    var billingPollPrice: Double {
        let metrics = billingServices.isEmpty
            ? 0 : BillingService.billedMetrics(for: billingServices)
        return Double(metrics) * CallMeter.Price.perGetMetricDataMetric
    }

    /// Manual only — this is the call that costs $0.01.
    func fetchCostBreakdown() {
        Task {
            cost.isRefreshing = true
            do {
                let breakdown = try await costExplorer.monthToDateByService()
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

    private func noteCredentialSuccess() async {
        credentialError = nil
        if let resolution = await client.resolution() {
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

    func applyConfiguration(_ new: Configuration) {
        config = new
        new.save()
        cloudWatch = CloudWatchService(client: client, config: new)
        budgets = BudgetsService(client: client, config: new)
        costExplorer = CostExplorerService(client: client, config: new)
        Task {
            await client.setProfile(new.profileName)
            refreshAllNow()
        }
    }
}
