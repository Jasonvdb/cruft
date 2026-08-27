import Darwin
import Foundation

/// Result of a clean operation. `freedBytes` is ground truth from a statfs
/// free-space delta on the volume (immune to APFS clones/hard links lying
/// about per-file allocation).
public struct CleanOutcome: Sendable, Codable {
    public let deletedPaths: [String]
    public let freedBytes: Int64

    public init(deletedPaths: [String], freedBytes: Int64) {
        self.deletedPaths = deletedPaths
        self.freedBytes = freedBytes
    }
}

/// A multi-item clean stopped after one or more items completed. Callers must
/// apply `outcome` before they surface `underlyingError`; otherwise the UI and
/// persisted stats can report paths that no longer exist. `completedItemIDs`
/// lets a caller retry only the unfinished items, including `.contentsOnly`
/// roots whose returned deleted paths are their children.
public struct PartialCleanFailure: Error, CustomStringConvertible {
    public let outcome: CleanOutcome
    public let completedItemIDs: [String]
    public let underlyingError: any Error

    public init(
        outcome: CleanOutcome,
        completedItemIDs: [String],
        underlyingError: any Error
    ) {
        self.outcome = outcome
        self.completedItemIDs = completedItemIDs
        self.underlyingError = underlyingError
    }

    public var description: String {
        String(describing: underlyingError)
    }
}

/// Why `ScanEngine.clean` refused to start.
public enum ScanEngineError: Error, Equatable {
    /// The category id is not in this engine's source list.
    case unknownCategory(CategoryID)
    /// A clean of this category is already in flight.
    case cleanAlreadyRunning(CategoryID)
    /// This source requires an explicit item subset.
    case wholeCategoryCleaningUnsupported(CategoryID)
}

/// A bounded app clean retry could not make safe progress.
public enum CleanRetryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `SafeDeleter` reported a missing path that was not one of the exact
    /// items still covered by the confirmed plan.
    case missingPathNotInRemainingItems(String)
    /// The bounded loop ended while confirmed plan items were still pending.
    case retryLimitExceeded(remainingItemCount: Int)

    public var description: String {
        switch self {
        case .missingPathNotInRemainingItems(let path):
            "Clean retry stopped because the missing path was not in the remaining plan: \(path)"
        case .retryLimitExceeded(let count):
            "Clean retry limit reached with \(count) item(s) remaining."
        }
    }
}

/// Pure retry rules shared by the app and CruftKit tests.
public enum CleanRetryPolicy {
    /// Removes one or more exact remaining items matching `path`. A mismatch
    /// is an error instead of a no-progress retry.
    public static func removingMissingItem(
        at path: String,
        from remainingItems: [CacheItem]
    ) throws -> [CacheItem] {
        let missingPath = normalizedPath(path)
        let retained = remainingItems.filter {
            normalizedPath($0.url.path(percentEncoded: false)) != missingPath
        }
        guard retained.count < remainingItems.count else {
            throw CleanRetryError.missingPathNotInRemainingItems(missingPath)
        }
        return retained
    }

    /// Returns an explicit terminal error whenever a bounded retry loop exits
    /// with items still pending.
    public static func terminalError(
        remainingItems: [CacheItem]
    ) -> CleanRetryError? {
        remainingItems.isEmpty
            ? nil
            : .retryLimitExceeded(remainingItemCount: remainingItems.count)
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// Orchestrates discovery, sizing, and cleaning. Key invariants (frozen):
///
/// - Per-category UNSTRUCTURED `Task(priority:)` handles in an in-flight map;
///   width (`ScanTrigger.width`) is enforced inside the actor with a FIFO
///   queue. Dedup-by-awaiting an in-flight handle is what gives priority
///   escalation when a `.utility` trigger joins a `.background` scan.
/// - Per-category generations (never one global counter): a settings change
///   invalidates only affected categories.
/// - Per-category state machine idle/scanning/cleaning: `clean` cancels that
///   category's scan, bumps its generation, deletes, then starts a fresh
///   `.postClean` re-size. `.postClean` never dedups against a pre-clean task.
/// - `events` stream + continuation are created in `init`, so events emitted
///   before the consumer attaches buffer instead of vanishing. Single consumer.
/// - Quiet gate: roots (and DerivedData children) modified within ~3 minutes
///   defer scheduled scans and badge menu-open refreshes instead of scanning
///   mid-build.
/// - Watchdog: a category with no walker progress for 15 s emits `.failed`
///   and its task is abandoned (a blocked syscall on a dead mount cannot be
///   cancelled; we stop waiting on it instead).
/// - Non-local volumes are not sized; iCloud-ubiquitous roots are excluded.
public actor ScanEngine {
    /// SINGLE consumer only: `AsyncStream` distributes values across
    /// iterators instead of replicating them, so a second consumer would
    /// silently steal events from the first (AppModel or the CLI).
    public nonisolated let events: AsyncStream<ScanEvent>
    private let eventContinuation: AsyncStream<ScanEvent>.Continuation

    private let sources: [any CacheSource]
    private let context: ScanContext
    private let measurer: any DirectoryMeasurer
    private let deleter: any ItemDeleting
    private let statsStore: StatsStore?
    /// Quiet-gate window: a root (or DerivedData child) modified within this
    /// many seconds defers `.scheduled` scans (`0` disables the gate).
    private let quietWindow: TimeInterval
    /// Watchdog: a category walk with no progress for this long is abandoned.
    private let watchdogTimeout: Duration
    /// Injectable volume gate. Production reads URL volume metadata; tests
    /// can prove root selection without a real remote mount.
    private let volumeIsLocal: @Sendable (URL) -> Bool

    private enum CategoryState {
        case idle, scanning, cleaning
    }

    private struct PendingScan {
        let category: CategoryID
        let trigger: ScanTrigger
    }

    /// Generation table + guarded event yield. Lock-based (not actor state)
    /// because the measurer's synchronous `partial` callback and abandoned
    /// walkers must consult it without hopping onto the actor.
    private let gate: ScanEventGate

    private var states: [CategoryID: CategoryState] = [:]
    private var inFlight: [CategoryID: Task<Void, Never>] = [:]
    private var watchdogs: [CategoryID: Task<Void, Never>] = [:]
    private var pendingQueue: [PendingScan] = []
    /// Set by `cancelAll` (quit path): no new scans ever start again.
    private var isShutDown = false
    private var lastDiscovered: [CategoryID: [CacheItem]] = [:]

    public init(
        sources: [any CacheSource],
        context: ScanContext,
        measurer: any DirectoryMeasurer = FoundationMeasurer(),
        deleter: any ItemDeleting,
        statsStore: StatsStore? = nil
    ) {
        self.init(
            sources: sources,
            context: context,
            measurer: measurer,
            deleter: deleter,
            statsStore: statsStore,
            quietWindow: 180,
            watchdogTimeout: .seconds(15)
        )
    }

    /// Test hook: injectable quiet window and watchdog timeout.
    init(
        sources: [any CacheSource],
        context: ScanContext,
        measurer: any DirectoryMeasurer,
        deleter: any ItemDeleting,
        statsStore: StatsStore?,
        quietWindow: TimeInterval,
        watchdogTimeout: Duration,
        volumeIsLocal: @escaping @Sendable (URL) -> Bool = { root in
            (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal != false
        }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ScanEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.eventContinuation = continuation
        self.gate = ScanEventGate(continuation: continuation)
        self.sources = sources
        self.context = context
        self.measurer = measurer
        self.deleter = deleter
        self.statsStore = statsStore
        self.quietWindow = quietWindow
        self.watchdogTimeout = watchdogTimeout
        self.volumeIsLocal = volumeIsLocal
    }

    /// Discover + size the given categories (nil = all registered, minus
    /// `context.excludedSourceIDs`). Dedups against in-flight scans except
    /// for `.postClean`, which always cancels-and-restarts.
    public func refresh(categories: Set<CategoryID>? = nil, trigger: ScanTrigger) async {
        for category in resolveCategories(categories) {
            switch states[category, default: .idle] {
            case .cleaning:
                continue
            case .scanning:
                if trigger == .postClean {
                    cancelScan(of: category)
                    enqueue(category, trigger: trigger)
                } else if let task = inFlight[category] {
                    // Dedup-by-awaiting: a detached await at the trigger's
                    // priority escalates a lower-priority in-flight walk.
                    Task(priority: trigger.taskPriority) { _ = await task.value }
                }
            case .idle:
                enqueue(category, trigger: trigger)
            }
        }
        startQueuedIfPossible()
    }

    /// Settings changed: cancel only the affected categories' tasks, bump
    /// their generations, rescan (at `.utility`, like any user-driven scan).
    public func invalidateAndRescan(categories: Set<CategoryID>) async {
        for category in resolveCategories(categories) {
            switch states[category, default: .idle] {
            case .cleaning:
                continue
            case .scanning:
                cancelScan(of: category)
            case .idle:
                gate.bump(category)
            }
            enqueue(category, trigger: .manual)
        }
        startQueuedIfPossible()
    }

    /// First-class clean: interlocked with scanning per the state machine.
    /// `items: nil` cleans every discovered item in the category (the last
    /// discovered set, or a fresh `discover()` if none exists).
    public func clean(category: CategoryID, items: [CacheItem]? = nil) async throws -> CleanOutcome {
        guard let source = source(for: category) else {
            throw ScanEngineError.unknownCategory(category)
        }
        if items == nil, !source.allowsWholeCategoryCleaning {
            throw ScanEngineError.wholeCategoryCleaningUnsupported(category)
        }
        if let invalid = items?.first(where: { !source.canClean(item: $0) }) {
            throw CacheSourceError.itemCleaningUnsupported(category, invalid.id)
        }
        guard states[category, default: .idle] != .cleaning else {
            throw ScanEngineError.cleanAlreadyRunning(category)
        }
        if states[category, default: .idle] == .scanning {
            cancelScan(of: category)
            startQueuedIfPossible()
        }
        states[category] = .cleaning
        var deletedPaths: [String] = []
        var completedItemIDs: [String] = []
        var freeBefore: Int64?
        do {
            let resolved: [CacheItem]
            if let items {
                resolved = items
            } else if let discovered = lastDiscovered[category] {
                resolved = discovered
            } else {
                resolved = try await source.discover(context: context)
            }

            freeBefore = Self.freeBytes(onVolumeOf: context.home)
            for item in resolved {
                let deleted = try await source.clean(item: item, context: context, using: deleter)
                deletedPaths.append(contentsOf: deleted.map { $0.path(percentEncoded: false) })
                completedItemIDs.append(item.id)
            }
            let freeAfter = Self.freeBytes(onVolumeOf: context.home)
            // Compensating write BEFORE the post-clean rescan is enqueued:
            // if the app quits (cancelAll) before that rescan finishes,
            // stats.json must not repaint pre-clean numbers on next launch.
            if let statsStore {
                await statsStore.noteCleaned(category: category, deletedPaths: deletedPaths)
            }
            finishClean(category)
            // Either statfs sample failing means the delta is meaningless:
            // report 0 freed rather than a phantom number (a one-sided
            // sample would otherwise leak the volume's total free space).
            let freedBytes = Self.freedBytes(before: freeBefore, after: freeAfter)
            return CleanOutcome(deletedPaths: deletedPaths, freedBytes: freedBytes)
        } catch {
            if !completedItemIDs.isEmpty {
                let outcome = CleanOutcome(
                    deletedPaths: deletedPaths,
                    freedBytes: Self.freedBytes(
                        before: freeBefore,
                        after: Self.freeBytes(onVolumeOf: context.home)))
                // Apply the same compensating write as a complete clean before
                // the rescan is enqueued or the typed partial result escapes.
                if let statsStore {
                    await statsStore.noteCleaned(
                        category: category,
                        deletedPaths: deletedPaths)
                }
                finishClean(category)
                throw PartialCleanFailure(
                    outcome: outcome,
                    completedItemIDs: completedItemIDs,
                    underlyingError: error)
            }
            finishClean(category)
            throw error
        }
    }

    private static func freedBytes(before: Int64?, after: Int64?) -> Int64 {
        guard let before, let after else { return 0 }
        return max(0, after - before)
    }

    /// Quit path: cancel every task, clear the queue, bump every generation
    /// so in-flight walkers can never emit again. Synchronous — no awaiting.
    public func cancelAll() {
        isShutDown = true
        for task in inFlight.values { task.cancel() }
        for task in watchdogs.values { task.cancel() }
        inFlight.removeAll()
        watchdogs.removeAll()
        pendingQueue.removeAll()
        for source in sources { gate.bump(source.id) }
        for (category, state) in states where state == .scanning {
            states[category] = .idle
        }
    }

    // MARK: - Scheduling

    private func resolveCategories(_ requested: Set<CategoryID>?) -> [CategoryID] {
        sources.map(\.id).filter { id in
            !context.excludedSourceIDs.contains(id)
                && (requested?.contains(id) ?? true)
        }
    }

    private func source(for id: CategoryID) -> (any CacheSource)? {
        sources.first { $0.id == id }
    }

    /// A queued category is already `.scanning` for dedup purposes — the
    /// walker just hasn't been granted a width slot yet.
    private func enqueue(_ category: CategoryID, trigger: ScanTrigger) {
        states[category] = .scanning
        pendingQueue.append(PendingScan(category: category, trigger: trigger))
    }

    /// FIFO with per-trigger width: the head starts only while fewer than
    /// `trigger.width` walkers are in flight (2 scheduled / 3 otherwise).
    private func startQueuedIfPossible() {
        guard !isShutDown else { return }
        // Width-aware pop, not strict FIFO: a queued `.manual` (width 3)
        // must not wait behind a `.scheduled` head (width 2) that the
        // current in-flight count blocks.
        while let index = pendingQueue.firstIndex(where: { inFlight.count < $0.trigger.width }) {
            startScan(pendingQueue.remove(at: index))
        }
    }

    private func startScan(_ pending: PendingScan) {
        let category = pending.category
        guard let source = source(for: category) else {
            states[category] = .idle
            return
        }
        let generation = gate.currentGeneration(for: category)
        let progress = ProgressBox()
        inFlight[category] = Task(priority: pending.trigger.taskPriority) { [weak self] in
            await self?.runScan(
                category: category,
                source: source,
                trigger: pending.trigger,
                generation: generation,
                progress: progress
            )
        }
        startWatchdog(for: category, generation: generation, progress: progress)
    }

    /// Cancels the category's walker (in flight or still queued), bumps its
    /// generation so any not-yet-delivered events are dropped, and frees its
    /// width slot.
    private func cancelScan(of category: CategoryID) {
        pendingQueue.removeAll { $0.category == category }
        inFlight[category]?.cancel()
        inFlight[category] = nil
        watchdogs[category]?.cancel()
        watchdogs[category] = nil
        gate.bump(category)
        states[category] = .idle
    }

    /// Walker handoff back to the actor. Stale generations are abandoned or
    /// cancelled walkers whose bookkeeping already happened — ignore them.
    private func scanCompleted(_ category: CategoryID, generation: Int) {
        guard gate.isCurrent(generation, for: category) else { return }
        states[category] = .idle
        inFlight[category] = nil
        watchdogs[category]?.cancel()
        watchdogs[category] = nil
        startQueuedIfPossible()
    }

    private func finishClean(_ category: CategoryID) {
        states[category] = .idle
        gate.bump(category)
        lastDiscovered[category] = nil
        // After cancelAll (quit path) the engine must stay quiet: a clean
        // finishing post-shutdown would otherwise respawn a post-clean
        // walker whose stats update can land after the app's final flush.
        guard !isShutDown else { return }
        enqueue(category, trigger: .postClean)
        startQueuedIfPossible()
    }

    // MARK: - Watchdog

    private func startWatchdog(for category: CategoryID, generation: Int, progress: ProgressBox) {
        let timeout = watchdogTimeout
        watchdogs[category] = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let remaining = timeout - progress.sinceLastProgress()
                if remaining <= .zero {
                    await self?.watchdogFired(category, generation: generation)
                    return
                }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
        }
    }

    /// No walker progress within the timeout: report the stall, then ABANDON
    /// the walker (drop the handle without awaiting or cancelling — a blocked
    /// syscall on a dead mount cannot be cancelled). The generation bump
    /// guarantees the abandoned task can never emit stale events or persist
    /// stale stats.
    private func watchdogFired(_ category: CategoryID, generation: Int) {
        guard gate.isCurrent(generation, for: category),
            states[category, default: .idle] == .scanning,
            inFlight[category] != nil
        else { return }
        gate.emit(.failed(category, message: "stalled"), category: category, generation: generation)
        gate.bump(category)
        inFlight[category] = nil
        watchdogs[category] = nil
        states[category] = .idle
        startQueuedIfPossible()
    }

    // MARK: - The per-category walk

    private func runScan(
        category: CategoryID,
        source: any CacheSource,
        trigger: ScanTrigger,
        generation: Int,
        progress: ProgressBox
    ) async {
        gate.emit(.categoryStarted(category), category: category, generation: generation)
        let scanRoot = source.scanRoot(context: context)?.cruftCanonical

        if let scanRoot, !volumeIsLocal(scanRoot) {
            gate.emit(.deferred(category, reason: .nonLocalVolume), category: category, generation: generation)
            scanCompleted(category, generation: generation)
            return
        }

        if trigger == .scheduled, source.defersScheduledScanForRecentRootActivity,
            let scanRoot,
            Self.recentlyModified(
                scanRoot,
                includeChildren: category == DerivedDataSource.id,
                within: quietWindow
            )
        {
            gate.emit(
                .deferred(category, reason: .buildActivityDetected),
                category: category, generation: generation)
            scanCompleted(category, generation: generation)
            return
        }

        let items: [CacheItem]
        do {
            items = try await source.discover(context: context)
        } catch is CancellationError {
            scanCompleted(category, generation: generation)
            return
        } catch {
            if let scanRoot, Self.exists(scanRoot), Self.isPermissionDenial(error) {
                gate.emit(
                    .deferred(category, reason: .permissionDenied),
                    category: category, generation: generation)
            } else {
                gate.emit(
                    .failed(category, message: String(describing: error)),
                    category: category, generation: generation)
            }
            scanCompleted(category, generation: generation)
            return
        }

        let localItems = items.filter { !Self.isUbiquitous($0.url) }
        gate.emit(.discovered(category, items: localItems), category: category, generation: generation)
        if gate.isCurrent(generation, for: category) {
            lastDiscovered[category] = localItems
        }
        progress.touch()

        var measured: [MeasuredItem] = []
        for item in localItems {
            if Task.isCancelled {
                scanCompleted(category, generation: generation)
                return
            }
            // Per-item partials build a snapshot from the items finished so
            // far plus the in-progress item; throttling (≤ 4 Hz) is the
            // measurer's contract.
            let completed = measured
            let gate = self.gate
            do {
                let size = try await measurer.measure(item.url) { partialSize in
                    progress.touch()
                    var partialItems = completed
                    partialItems.append(MeasuredItem(item: item, size: partialSize))
                    gate.emit(
                        .partial(category, CategorySnapshot(categoryID: category, items: partialItems)),
                        category: category, generation: generation)
                }
                measured.append(MeasuredItem(item: item, size: size))
                progress.touch()
            } catch is CancellationError {
                scanCompleted(category, generation: generation)
                return
            } catch {
                // Per-item measure failure is a category failure: the totals
                // would otherwise silently describe a subset of the category.
                gate.emit(
                    .failed(category, message: String(describing: error)),
                    category: category, generation: generation)
                scanCompleted(category, generation: generation)
                return
            }
        }

        let snapshot = CategorySnapshot(categoryID: category, items: measured, updatedAt: Date())
        if gate.isCurrent(generation, for: category) {
            gate.emit(.finished(category, snapshot), category: category, generation: generation)
            if let statsStore {
                let updateToken = await statsStore.update(snapshot)
                // The await above is a suspension point: a clean() may have
                // started (bumping the generation) while this walker was
                // suspended, making the just-persisted snapshot pre-clean
                // truth. Re-check and remove only this walker's own write. A
                // later clean remainder or finished scan must survive.
                if let updateToken,
                    !gate.isCurrent(generation, for: category)
                {
                    await statsStore.invalidate(
                        category: category,
                        ifCurrent: updateToken)
                }
            }
        }
        scanCompleted(category, generation: generation)
    }

    // MARK: - Guards

    /// Quiet gate, one stat(2) per path: true when the root (or, for
    /// DerivedData, any direct child) was modified within `window` seconds.
    private static func recentlyModified(
        _ root: URL, includeChildren: Bool, within window: TimeInterval
    ) -> Bool {
        guard window > 0 else { return false }
        let rootPath = root.path(percentEncoded: false)
        var paths = [rootPath]
        if includeChildren,
            let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath)
        {
            paths += names.map { rootPath + "/" + $0 }
        }
        let now = Date()
        for path in paths {
            var status = stat()
            guard stat(path, &status) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) < window { return true }
        }
        return false
    }

    /// iCloud Drive material is never sized or cleaned.
    private static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// TCC denial shapes: NSCocoaError 257 or raw POSIX EPERM/EACCES.
    private static func isPermissionDenial(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
            nsError.code == CocoaError.fileReadNoPermission.rawValue
        {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES))
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// statfs(2) free bytes on the volume containing `url` — the ground
    /// truth both sides of `CleanOutcome.freedBytes`. nil on statfs failure
    /// so callers can tell "couldn't sample" from "zero free".
    private static func freeBytes(onVolumeOf url: URL) -> Int64? {
        var status = statfs()
        guard statfs(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return Int64(status.f_bfree) * Int64(status.f_bsize)
    }
}

/// Generation table + the single guarded path every `ScanEvent` yield goes
/// through: events stamped with a (category, generation) that is no longer
/// current are dropped, which is what makes cancelled and abandoned walkers
/// harmless. Lock-based so the measurer's synchronous `partial` callback can
/// emit without hopping onto the engine actor.
private final class ScanEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [CategoryID: Int] = [:]
    private let continuation: AsyncStream<ScanEvent>.Continuation

    init(continuation: AsyncStream<ScanEvent>.Continuation) {
        self.continuation = continuation
    }

    func currentGeneration(for category: CategoryID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generations[category, default: 0]
    }

    func bump(_ category: CategoryID) {
        lock.lock()
        generations[category, default: 0] += 1
        lock.unlock()
    }

    func isCurrent(_ generation: Int, for category: CategoryID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[category, default: 0] == generation
    }

    func emit(_ event: ScanEvent, category: CategoryID, generation: Int) {
        guard isCurrent(generation, for: category) else { return }
        continuation.yield(event)
    }
}

/// Last-progress timestamp shared between a walker (touches) and its
/// watchdog (reads). The measurer's `partial` callback is synchronous, so
/// this is a lock, not an actor.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() {
        lock.lock()
        last = ContinuousClock.now
        lock.unlock()
    }

    func sinceLastProgress() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return ContinuousClock.now - last
    }
}
