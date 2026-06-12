import CruftKit
import Foundation

/// Periodic background rescans via `NSBackgroundActivityScheduler` — the
/// system decides the exact moment within the tolerance window, batching
/// with other maintenance work.
///
/// DEADLINE CHOICE (documented): the engine has no per-trigger cancel, and
/// `engine.refresh` ENQUEUES walks and returns — so the 15-minute race
/// below almost always resolves instantly on the refresh side and reports
/// `.finished` while the walks proceed at `.background` (kernel I/O
/// throttling via the trigger's task priority). If the deadline ever fires
/// first, the activity reports `.deferred` and the scan keeps running at
/// `.background`; the engine's own watchdog reaps stalled walkers. We never
/// invalidate the engine mid-scan to fake a cancel.
@MainActor
final class RescanScheduler {
    static let activityIdentifier = "com.jasonvdb.cruft.rescan"
    /// Wall-clock budget for one scheduled refresh before reporting
    /// `.deferred` (see the deadline choice above).
    private static let refreshDeadline: Duration = .seconds(15 * 60)

    private var scheduler: NSBackgroundActivityScheduler?
    private var engine: ScanEngine
    private var intervalHours: Double
    /// CRUFT_DEBUG_SCHEDULER_INTERVAL_SECONDS overrides the interval so the
    /// phase gate can observe a firing within seconds. Firings log
    /// `CRUFT_SCHED_FIRED` to stderr either way.
    private let debugIntervalSeconds: TimeInterval?

    init(
        engine: ScanEngine,
        intervalHours: Double,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.engine = engine
        self.intervalHours = intervalHours
        self.debugIntervalSeconds = environment["CRUFT_DEBUG_SCHEDULER_INTERVAL_SECONDS"]
            .flatMap(TimeInterval.init)
        register()
    }

    /// The engine was rebuilt (projects-root change): future firings must
    /// hit the new engine, so re-register with it.
    func setEngine(_ engine: ScanEngine) {
        self.engine = engine
        register()
    }

    /// Interval setting changed: re-register at the new cadence.
    func setIntervalHours(_ hours: Double) {
        guard hours != intervalHours else { return }
        intervalHours = hours
        register()
    }

    /// Quit path: unregister the activity from the system.
    func invalidate() {
        scheduler?.invalidate()
        scheduler = nil
    }

    private func register() {
        scheduler?.invalidate()
        let interval = debugIntervalSeconds ?? intervalHours * 3600
        let activity = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = interval / 8
        activity.qualityOfService = .background
        let engine = engine
        // `shouldDefer` is designed to be read inside the activity block;
        // the scheduler object is not Sendable, hence the unsafe (read-only,
        // documented-API) capture.
        nonisolated(unsafe) let schedulerHandle = activity
        activity.schedule { completion in
            // Cheap synchronous gates first: power/thermal/battery, then the
            // system's own deferral hint.
            guard !ScanGate.isGated, !schedulerHandle.shouldDefer else {
                completion(.deferred)
                return
            }
            FileHandle.standardError.write(Data("CRUFT_SCHED_FIRED\n".utf8))
            Task(priority: .background) {
                let outcome = await withTaskGroup(
                    of: NSBackgroundActivityScheduler.Result.self
                ) { group in
                    group.addTask(priority: .background) {
                        await engine.refresh(trigger: .scheduled)
                        return .finished
                    }
                    group.addTask {
                        try? await Task.sleep(for: Self.refreshDeadline)
                        return .deferred
                    }
                    let first = await group.next() ?? .finished
                    group.cancelAll()
                    return first
                }
                completion(outcome)
            }
        }
        scheduler = activity
    }
}
