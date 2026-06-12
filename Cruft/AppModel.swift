import AppKit
import CruftKit
import Foundation
import Observation

/// The app's single model object: owns the scan context, the stats store,
/// the engine, and the `MenuState` the views render. All presentation rules
/// live in `MenuState` (CruftKit); this class only routes lifecycle, events,
/// and the debug harness.
@Observable @MainActor
final class AppModel {
    /// Launch scan runs only when persisted stats are missing a category or
    /// older than this — opening the laptop must not trigger a login storm.
    private static let launchStaleness: TimeInterval = 4 * 60 * 60
    /// Menu-open refresh runs only when nothing refreshed within this window.
    private static let menuOpenStaleness: TimeInterval = 30 * 60

    private(set) var menuState: MenuState

    private let sources: [any CacheSource]
    private let context: ScanContext
    private let statsStore: StatsStore
    private let engine: ScanEngine
    /// CRUFT_DEBUG_DUMP harness (verification): once every category reaches
    /// a terminal state, print one stderr line per category and keep running.
    private let debugDump: Bool

    private var started = false
    private var eventsTask: Task<Void, Never>?
    private var lastRefreshAt: Date?
    private var terminalCategories: Set<CategoryID> = []
    private var debugDumpEmitted = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let sources = SourceRegistry.allSources
        self.sources = sources

        // CRUFT_HOME points scans at a fixture home (testing). Fixture runs
        // must not pollute the real stats file, so an overridden home keeps
        // its stats inside the fixture tree.
        let overrideHome = environment["CRUFT_HOME"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        let context = ScanContext(
            home: overrideHome ?? FileManager.default.homeDirectoryForCurrentUser)
        self.context = context
        let statsStore = StatsStore(
            fileURL: overrideHome == nil
                ? StatsStore.defaultFileURL()
                : context.home.appending(path: "Library/Application Support/Cruft/stats.json"))
        self.statsStore = statsStore
        // SafeDeleter refuses any home that is neither the real $HOME nor a
        // system temp area, so a bad CRUFT_HOME fails loudly at launch.
        self.engine = ScanEngine(
            sources: sources,
            context: context,
            deleter: try! SafeDeleter(home: context.home, mode: .live),
            statsStore: statsStore
        )
        self.debugDump = environment["CRUFT_DEBUG_DUMP"] != nil
        self.menuState = MenuState(sources: sources, persisted: [])
        Task { await self.start() }
    }

    /// The status item title: the formatted total once any value is known,
    /// nil (icon) before that.
    var menuBarTitle: String? {
        guard menuState.rows.contains(where: { $0.bytes != nil }) else { return nil }
        return Self.formattedBytes(menuState.displayedTotalBytes)
    }

    /// When the displayed numbers were last confirmed by a finished scan.
    var newestDisplayedUpdate: Date? {
        menuState.rows.compactMap { row -> Date? in
            if case .idle(.some(let date)) = row.activity { return date }
            return nil
        }.max()
    }

    /// Launch sequence (order is load-bearing): load persisted stats ONCE →
    /// paint MenuState → attach the engine's SINGLE events consumer → only
    /// then maybe refresh. Staleness-routed: fresh complete stats skip the
    /// launch scan entirely.
    func start() async {
        guard !started else { return }
        started = true
        let persisted = await statsStore.load()
        menuState = MenuState(sources: sources, persisted: persisted)
        attachEventsConsumer()
        // The debug dump exists to compare a full live scan against the CLI,
        // so it always scans regardless of staleness.
        if persistedStatsAreIncompleteOrStale(persisted) || debugDump {
            lastRefreshAt = Date()
            await engine.refresh(trigger: .launch)
        }
    }

    func refreshNow() {
        lastRefreshAt = Date()
        Task { await engine.refresh(trigger: .manual) }
    }

    /// The menu just opened: refresh quietly when nothing refreshed recently.
    func menuOpened() {
        guard started else { return }
        let reference = [lastRefreshAt, newestDisplayedUpdate].compactMap { $0 }.max()
        if let reference, Date().timeIntervalSince(reference) <= Self.menuOpenStaleness {
            return
        }
        lastRefreshAt = Date()
        Task { await engine.refresh(trigger: .menuOpened) }
    }

    /// Quit path (the only one — LSUIElement apps have no dock menu): stop
    /// the engine for good, flush coalesced stats, then terminate.
    func quit() {
        Task {
            await engine.cancelAll()
            await statsStore.flush()
            eventsTask?.cancel()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Events

    /// The engine's `events` stream is SINGLE-consumer; this task is that
    /// consumer for the app's whole lifetime and must attach before the
    /// first refresh.
    private func attachEventsConsumer() {
        let events = engine.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ScanEvent) {
        menuState.apply(event)
        switch event {
        case .categoryStarted(let id):
            terminalCategories.remove(id)
        case .discovered, .partial:
            break
        case .finished(let id, _), .deferred(let id, _), .failed(let id, _):
            terminalCategories.insert(id)
            emitDebugDumpIfComplete()
        }
    }

    // MARK: - Staleness

    private func persistedStatsAreIncompleteOrStale(_ persisted: [CategorySnapshot]) -> Bool {
        let persistedIDs = Set(persisted.map(\.categoryID))
        guard scannableCategoryIDs.isSubset(of: persistedIDs) else { return true }
        guard let oldest = persisted.compactMap(\.updatedAt).min() else { return true }
        return Date().timeIntervalSince(oldest) > Self.launchStaleness
    }

    private var scannableCategoryIDs: Set<CategoryID> {
        Set(sources.map(\.id)).subtracting(context.excludedSourceIDs)
    }

    // MARK: - Debug harness

    /// `CRUFT_DUMP <id> <bytes> <itemCount>` per category once every
    /// category is terminal, then `CRUFT_DUMP_DONE` — printed to stderr so
    /// verification scripts can diff the app's numbers against the CLI's.
    /// The app keeps running afterwards.
    private func emitDebugDumpIfComplete() {
        guard debugDump, !debugDumpEmitted,
            terminalCategories.isSuperset(of: scannableCategoryIDs)
        else { return }
        debugDumpEmitted = true
        var lines = menuState.rows.map { row in
            "CRUFT_DUMP \(row.id.rawValue) \(row.bytes ?? 0) \(row.itemCount ?? 0)"
        }
        lines.append("CRUFT_DUMP_DONE")
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Formatting

    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
