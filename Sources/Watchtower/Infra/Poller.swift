import Foundation

/// A repeating task with exponential backoff and an interruptible sleep.
///
/// The sleep is a separate child task so `refreshNow()` can cancel just the wait without
/// tearing down the loop. Backoff exists because the alternative — retrying a failing call
/// every 60 seconds forever — is how a monitoring app quietly bills you while you sleep.
final class Poller {

    private let name: String
    private let interval: () -> TimeInterval
    private let action: () async -> Bool     // true on success

    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// Never back off past this: beyond a quarter hour the app is effectively off, and the
    /// user should see stale-data warnings rather than a silent retry storm.
    private let maximumBackoff: TimeInterval = 15 * 60

    init(name: String, interval: @escaping () -> TimeInterval, action: @escaping () async -> Bool) {
        self.name = name
        self.interval = interval
        self.action = action
    }

    var isRunning: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.action()
                if Task.isCancelled { return }
                self.consecutiveFailures = succeeded ? 0 : self.consecutiveFailures + 1
                await self.wait(seconds: self.nextDelay())
            }
        }
    }

    func stop() {
        sleepTask?.cancel()
        sleepTask = nil
        loopTask?.cancel()
        loopTask = nil
    }

    /// Wake the loop early. Harmless if it is already running an action.
    func refreshNow() {
        sleepTask?.cancel()
    }

    private func nextDelay() -> TimeInterval {
        let base = max(interval(), 1)
        guard consecutiveFailures > 0 else { return base }
        let scaled = base * pow(2, Double(min(consecutiveFailures, 8)))
        return min(scaled, maximumBackoff)
    }

    private func wait(seconds: TimeInterval) async {
        let task = Task { () -> Void in
            // Cancellation is the expected exit path here: refreshNow() cancels this sleep
            // to wake the loop early, which is not an error.
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { }
        }
        sleepTask = task
        await task.value
        sleepTask = nil
    }
}
