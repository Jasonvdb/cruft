import AppKit
import CruftKit
import Darwin
import Foundation
import Observation

/// One clean awaiting user confirmation — everything the dialog renders,
/// precomputed here so the view stays a thin rendering layer.
struct PendingCleanConfirmation {
    struct Entry: Identifiable {
        let id: CategoryID
        let displayName: String
        let itemCount: Int
        let bytes: Int64
    }

    let title: String
    /// Registry order, like the menu rows.
    let entries: [Entry]
    let totalItemCount: Int
    let estimatedBytes: Int64
    /// Built separately by AppModel so the view styles by LIST (orange vs
    /// red), never by string-matching warning text. `plan.warnings` still
    /// carries both combined for CLI parity.
    let processWarnings: [String]
    let destructiveWarnings: [String]
    let plan: CleanPlan
}

/// Outcome of the last confirmed clean — drives the transient result line.
struct CleanResult {
    struct CategoryResult: Identifiable {
        let id: CategoryID
        let displayName: String
        let deletedItems: Int
    }

    let freedBytes: Int64
    let deletedItems: Int
    let perCategory: [CategoryResult]
    /// First error hit, if any. Categories cleaned before it stay cleaned;
    /// the run stops there.
    let errorMessage: String?
}

/// The app's single model object: owns the scan context, the stats store,
/// the engine, and the `MenuState` the views render. All presentation rules
/// live in `MenuState` (CruftKit); this class only routes lifecycle, events,
/// cleaning, and the debug harness.
@Observable @MainActor
final class AppModel {
    /// Launch scan runs only when persisted stats are missing a category or
    /// older than this — opening the laptop must not trigger a login storm.
    private static let launchStaleness: TimeInterval = 4 * 60 * 60
    /// Menu-open refresh runs only when nothing refreshed within this window.
    private static let menuOpenStaleness: TimeInterval = 30 * 60

    private(set) var menuState: MenuState
    /// Non-nil while a clean awaits confirmation; the view renders it as the
    /// in-window confirmation dialog.
    private(set) var pendingPlan: PendingCleanConfirmation?
    /// Result of the last confirmed clean; cleared on dismiss or the next
    /// refresh.
    private(set) var lastCleanResult: CleanResult?
    /// True while a confirmed clean runs. Guards re-entry at the model layer
    /// (the engine would throw `cleanAlreadyRunning` anyway).
    private(set) var isCleaning = false
    /// Transient "nothing to clean" notice (auto-clears after a moment).
    private(set) var showsNothingToClean = false

    /// User settings (UserDefaults-backed; ephemeral under CRUFT_HOME).
    let settings: SettingsStore

    private let sources: [any CacheSource]
    /// Effective home (real $HOME or the CRUFT_HOME fixture) — kept so
    /// `applySettingsChange()` can rebuild the context around a new
    /// projects root.
    private let homeURL: URL
    /// Rebuilt (with the engine) when the projects root changes.
    private var context: ScanContext
    private let statsStore: StatsStore
    private var engine: ScanEngine
    private var rescanScheduler: RescanScheduler?
    /// CRUFT_DEBUG_DUMP harness (verification): once every category reaches
    /// a terminal state, print one stderr line per category and keep running.
    private let debugDump: Bool
    /// CRUFT_DEBUG_AUTOCLEAN harness (verification): after the debug dump,
    /// drive the real clean-all model path once. Armed ONLY when CRUFT_HOME
    /// overrides the home; re-guarded in `runDebugAutoCleanIfArmed()`.
    private let debugAutoClean: Bool

    private var started = false
    private var eventsTask: Task<Void, Never>?
    private var lastRefreshAt: Date?
    private var terminalCategories: Set<CategoryID> = []
    private var debugDumpEmitted = false
    private var debugAutoCleanStarted = false
    /// Latest known snapshot per category (persisted stats at launch, then
    /// every `.finished` event) — what clean plans are built from.
    private var latestSnapshots: [CategoryID: CategorySnapshot] = [:]
    private var nothingToCleanClearTask: Task<Void, Never>?

    /// User overrides for Clean All membership, read live from settings at
    /// plan time — toggles never rebuild the engine (they only affect
    /// planning). CleanPlanner enforces destructive-only-via-explicit-include.
    private var cleanAllUserIncluded: Set<CategoryID> { settings.cleanAllIncludedIDs }
    private var cleanAllUserExcluded: Set<CategoryID> { settings.cleanAllExcludedIDs }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let sources = SourceRegistry.allSources
        self.sources = sources
        let settings = SettingsStore(environment: environment)
        self.settings = settings

        // CRUFT_HOME points scans at a fixture home (testing). Fixture runs
        // must not pollute the real stats file, so an overridden home keeps
        // its stats inside the fixture tree.
        let overrideHome = environment["CRUFT_HOME"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        let homeURL = overrideHome ?? FileManager.default.homeDirectoryForCurrentUser
        self.homeURL = homeURL
        let context = ScanContext(home: homeURL, projectsRoot: settings.projectsRootURL)
        self.context = context
        let statsStore = StatsStore(
            fileURL: overrideHome == nil
                ? StatsStore.defaultFileURL()
                : context.home.appending(path: "Library/Application Support/Cruft/stats.json"))
        self.statsStore = statsStore
        // SafeDeleter refuses any home that is neither the real $HOME nor a
        // system temp area, so a bad CRUFT_HOME fails loudly at launch.
        let engine = Self.makeEngine(sources: sources, context: context, statsStore: statsStore)
        self.engine = engine
        self.debugDump = environment["CRUFT_DEBUG_DUMP"] != nil
        // HARD GUARD half 1: the autoclean harness can only arm when the
        // home is overridden — it must never exist against the real $HOME.
        self.debugAutoClean =
            environment["CRUFT_DEBUG_AUTOCLEAN"] != nil && overrideHome != nil
        self.menuState = MenuState(sources: sources, persisted: [])
        self.rescanScheduler = RescanScheduler(
            engine: engine,
            intervalHours: settings.rescanIntervalHours,
            environment: environment)
        Task { await self.start() }
    }

    private static func makeEngine(
        sources: [any CacheSource], context: ScanContext, statsStore: StatsStore
    ) -> ScanEngine {
        ScanEngine(
            sources: sources,
            context: context,
            deleter: try! SafeDeleter(home: context.home, mode: .live),
            statsStore: statsStore
        )
    }

    /// The status item title: the formatted total once any value is known,
    /// nil (icon) before that.
    var menuBarTitle: String? {
        guard menuState.rows.contains(where: { $0.bytes != nil }) else { return nil }
        return Self.formattedBytes(menuState.displayedTotalBytes)
    }

    /// The EFFECTIVE projects root (the context's, after defaulting) — what
    /// the Settings window displays.
    var projectsRootDisplayPath: String {
        context.projectsRoot.path(percentEncoded: false)
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
        if debugDump {
            // Status read-back observable for the phase gate (no
            // registration happens here — only the Settings toggle does).
            let status = LaunchAtLogin.status
            FileHandle.standardError.write(
                Data("CRUFT_LAUNCH_AT_LOGIN status=\(status.rawValue)\n".utf8))
        }
        let persisted = await statsStore.load()
        menuState = MenuState(sources: sources, persisted: persisted)
        latestSnapshots = Dictionary(
            persisted.map { ($0.categoryID, $0) }, uniquingKeysWith: { first, _ in first })
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
        lastCleanResult = nil
        Task { await engine.refresh(trigger: .manual) }
    }

    /// The menu just opened: refresh quietly when nothing refreshed recently.
    func menuOpened() {
        guard started else { return }
        refreshExternallyCleanedCategories()
        let reference = [lastRefreshAt, newestDisplayedUpdate].compactMap { $0 }.max()
        if let reference, Date().timeIntervalSince(reference) <= Self.menuOpenStaleness {
            return
        }
        lastRefreshAt = Date()
        lastCleanResult = nil
        Task { await engine.refresh(trigger: .menuOpened) }
    }

    /// Menu-open external-clean check (perf plan): someone may have deleted
    /// displayed items outside cruft (`rm -rf`, Xcode's own cleanups). One
    /// cheap stat(2) existence pass over the latest snapshots' item paths,
    /// off-main; any category with a missing path is rescanned regardless of
    /// the 30-minute staleness window.
    private func refreshExternallyCleanedCategories() {
        let pathsByCategory = latestSnapshots.mapValues { snapshot in
            snapshot.items.map { $0.item.url.path(percentEncoded: false) }
        }
        guard !pathsByCategory.isEmpty else { return }
        let engine = engine
        Task.detached(priority: .utility) {
            var missing: Set<CategoryID> = []
            for (category, paths) in pathsByCategory {
                for path in paths {
                    var status = stat()
                    if stat(path, &status) != 0 {
                        missing.insert(category)
                        break
                    }
                }
            }
            guard !missing.isEmpty else { return }
            await engine.refresh(categories: missing, trigger: .menuOpened)
        }
    }

    // MARK: - Settings

    /// Settings just changed (called by SettingsView after any edit).
    /// Interval changes re-register the scheduler; a projects-root change
    /// rebuilds the scan stack: the ScanContext is immutable, the engine's
    /// event stream is single-consumer, and `cancelAll` is terminal — so
    /// "apply" means tear down the consumer task, cancelAll the old engine,
    /// build a fresh engine + consumer (same StatsStore), and rescan the
    /// in-repo-build category. Clean All toggles deliberately reach none of
    /// this — they are read live at plan time.
    func applySettingsChange() {
        rescanScheduler?.setIntervalHours(settings.rescanIntervalHours)

        let newContext = ScanContext(home: homeURL, projectsRoot: settings.projectsRootURL)
        let newRoot = newContext.projectsRoot.path(percentEncoded: false)
        guard newRoot != context.projectsRoot.path(percentEncoded: false) else { return }

        eventsTask?.cancel()
        let oldEngine = engine
        context = newContext
        let newEngine = Self.makeEngine(sources: sources, context: newContext, statsStore: statsStore)
        engine = newEngine
        attachEventsConsumer()
        rescanScheduler?.setEngine(newEngine)

        // The old root's numbers are no longer truthful: drop the retained
        // row (the fresh scan's partials repaint from zero) and the stale
        // snapshot — a clean planned from it would target old-root paths.
        latestSnapshots[InRepoBuildSource.id] = nil
        menuState.noteCleaned(InRepoBuildSource.id)
        lastRefreshAt = Date()
        Task {
            await oldEngine.cancelAll()
            await self.statsStore.invalidate(category: InRepoBuildSource.id)
            await newEngine.refresh(categories: [InRepoBuildSource.id], trigger: .manual)
        }
    }

    /// Quit path (the only one — LSUIElement apps have no dock menu): stop
    /// the engine for good, flush coalesced stats, then terminate.
    func quit() {
        rescanScheduler?.invalidate()
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
        case .finished(let id, let snapshot):
            latestSnapshots[id] = snapshot
            terminalCategories.insert(id)
            emitDebugDumpIfComplete()
        case .deferred(let id, _), .failed(let id, _):
            terminalCategories.insert(id)
            emitDebugDumpIfComplete()
        }
    }

    // MARK: - Cleaning

    /// Builds a one-category plan and publishes the confirmation dialog
    /// (empty plan → transient "nothing to clean", no dialog). Per-category
    /// clean is always available — including the destructive Archives,
    /// whose plan carries the prominent destructive warning.
    func requestClean(category: CategoryID) {
        guard pendingPlan == nil, !isCleaning else { return }
        let planner = CleanPlanner(sources: sources)
        let snapshots = Array(latestSnapshots.values)
        guard !planner.planCategory(category, snapshots: snapshots).itemsByCategory.isEmpty
        else {
            noteNothingToClean()
            return
        }
        let processWarnings = ProcessGuard().warnings(for: [category])
        let plan = planner.planCategory(
            category,
            snapshots: snapshots,
            processWarnings: processWarnings
        )
        let displayName = sources.first { $0.id == category }?.displayName ?? category.rawValue
        pendingPlan = makeConfirmation(
            title: "Clean \(displayName)", plan: plan, processWarnings: processWarnings)
    }

    /// Clean All membership comes from the planner's defaults plus the
    /// user's include/exclude sets from Settings — destructive categories
    /// (Archives) join only via the explicit opt-in toggle there.
    func requestCleanAll() {
        guard pendingPlan == nil, !isCleaning else { return }
        let planner = CleanPlanner(sources: sources)
        let snapshots = Array(latestSnapshots.values)
        // Two passes: the draft determines WHICH categories are in, so the
        // process warnings cover exactly the planned category ids.
        let draft = planner.planCleanAll(
            snapshots: snapshots,
            userIncluded: cleanAllUserIncluded,
            userExcluded: cleanAllUserExcluded
        )
        guard !draft.itemsByCategory.isEmpty else {
            noteNothingToClean()
            return
        }
        let processWarnings = ProcessGuard().warnings(for: Set(draft.itemsByCategory.keys))
        let plan = planner.planCleanAll(
            snapshots: snapshots,
            userIncluded: cleanAllUserIncluded,
            userExcluded: cleanAllUserExcluded,
            processWarnings: processWarnings
        )
        pendingPlan = makeConfirmation(title: "Clean All", plan: plan, processWarnings: processWarnings)
    }

    func cancelPendingClean() {
        pendingPlan = nil
    }

    /// Runs the confirmed plan. `isCleaning` makes a second confirm
    /// impossible at the model layer while one runs.
    func confirmPendingClean() {
        guard let pending = pendingPlan, !isCleaning else { return }
        pendingPlan = nil
        isCleaning = true
        lastCleanResult = nil
        Task { await runClean(pending.plan) }
    }

    /// Dismiss the result line by hand (it also auto-clears on refresh).
    func dismissCleanResult() {
        lastCleanResult = nil
    }

    private func runClean(_ plan: CleanPlan) async {
        var freedBytes: Int64 = 0
        var deletedItems = 0
        var perCategory: [CleanResult.CategoryResult] = []
        var errorMessage: String?
        // Registry order, matching the menu rows.
        categories: for source in sources {
            guard var remaining = plan.itemsByCategory[source.id] else { continue }
            var categoryDeleted = 0
            // An item can vanish between the dialog opening and now (an
            // external `rm`, Xcode's own cleanup). SafeDeleter reports that
            // as `.doesNotExist`; drop JUST that item and retry the rest —
            // everything else was still consented to. Any other error
            // aborts the whole run, as before. Bounded: each retry removes
            // one vanished `.entireItem` (or re-lists a `.contentsOnly`
            // root, which then skips its vanished child).
            var retriesLeft = remaining.count + 3
            while !remaining.isEmpty, retriesLeft > 0 {
                retriesLeft -= 1
                do {
                    let outcome = try await engine.clean(category: source.id, items: remaining)
                    freedBytes += outcome.freedBytes
                    categoryDeleted += outcome.deletedPaths.count
                    remaining = []
                } catch SafeDeleterError.doesNotExist(let path) {
                    let vanished = Self.normalizedPath(path)
                    remaining.removeAll {
                        Self.normalizedPath($0.url.path(percentEncoded: false)) == vanished
                    }
                } catch {
                    // Stop on any real error: already-cleaned categories
                    // stay cleaned, the message reaches the result line,
                    // never crash. (The engine's error path still enqueues
                    // a `.postClean` rescan, so the display self-corrects.)
                    errorMessage = String(describing: error)
                    break categories
                }
            }
            deletedItems += categoryDeleted
            perCategory.append(CleanResult.CategoryResult(
                id: source.id,
                displayName: source.displayName,
                deletedItems: categoryDeleted))
            // The retained number is no longer truthful: drop it and let
            // the engine's automatic `.postClean` rescan repaint from
            // zero (MenuState.noteCleaned owns that rule).
            latestSnapshots[source.id] = nil
            menuState.noteCleaned(source.id)
        }
        lastCleanResult = CleanResult(
            freedBytes: freedBytes,
            deletedItems: deletedItems,
            perCategory: perCategory,
            errorMessage: errorMessage)
        isCleaning = false
        finishDebugAutoCleanIfArmed(freedBytes: freedBytes)
    }

    /// SafeDeleter compares (and reports) percent-decoded paths; directory
    /// URLs from different APIs may disagree only on a trailing slash.
    private static func normalizedPath(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func makeConfirmation(
        title: String, plan: CleanPlan, processWarnings: [String]
    ) -> PendingCleanConfirmation {
        let entries = sources.compactMap { source -> PendingCleanConfirmation.Entry? in
            guard let items = plan.itemsByCategory[source.id] else { return nil }
            return PendingCleanConfirmation.Entry(
                id: source.id,
                displayName: source.displayName,
                itemCount: items.count,
                bytes: latestSnapshots[source.id]?.totalBytes ?? 0)
        }
        // Built from source flags, not by matching warning strings: any
        // destructive category in the plan carries the planner's warning.
        let hasDestructive = sources.contains {
            $0.isDestructive && plan.itemsByCategory[$0.id] != nil
        }
        return PendingCleanConfirmation(
            title: title,
            entries: entries,
            totalItemCount: entries.reduce(0) { $0 + $1.itemCount },
            estimatedBytes: plan.estimatedBytes,
            processWarnings: processWarnings,
            destructiveWarnings: hasDestructive ? [CleanPlanner.destructiveWarning] : [],
            plan: plan)
    }

    private func noteNothingToClean() {
        showsNothingToClean = true
        nothingToCleanClearTask?.cancel()
        nothingToCleanClearTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showsNothingToClean = false
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
        runDebugAutoCleanIfArmed()
    }

    /// CRUFT_DEBUG_AUTOCLEAN: drive the REAL model path (requestCleanAll →
    /// confirmPendingClean) once the first dump is out. HARD GUARD half 2,
    /// in code not convention: refuses unless the scan home was overridden
    /// away from the real home directory.
    private func runDebugAutoCleanIfArmed() {
        guard debugAutoClean, !debugAutoCleanStarted else { return }
        // Positive check, not a real-home comparison: the harness runs ONLY
        // against fixture homes in a system temp area, so any other home —
        // real, subdirectory of real, network, anything — is refused.
        let homePath = context.home.path(percentEncoded: false)
        guard systemTempAreaPrefixes.contains(where: homePath.hasPrefix) else {
            FileHandle.standardError.write(Data("CRUFT_AUTOCLEAN_REFUSED non-fixture-home\n".utf8))
            return
        }
        debugAutoCleanStarted = true
        requestCleanAll()
        confirmPendingClean()
    }

    /// Second half of the autoclean harness: report the freed bytes, then
    /// re-arm the dump so the post-clean (zero) numbers are printed once the
    /// `.postClean` rescans all finish. The direct call covers the race
    /// where every rescan already finished before the clean task resumed.
    private func finishDebugAutoCleanIfArmed(freedBytes: Int64) {
        guard debugAutoCleanStarted else { return }
        FileHandle.standardError.write(Data("CRUFT_CLEAN_DONE freed=\(freedBytes)\n".utf8))
        debugDumpEmitted = false
        emitDebugDumpIfComplete()
    }

    // MARK: - Formatting

    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
