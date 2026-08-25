import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

// Phase 5 integration gate: the full clean flow the GUI orchestrates —
// scan → CleanPlanner plan → engine.clean per category → MenuState
// noteCleaned + postClean repaint — exercised against the canonical fixture
// home. (AppModel itself is app-target-only; everything it calls lives here.)

// MARK: - Event collection (the stream's SINGLE consumer per engine)

private actor EventBox {
    private(set) var events: [ScanEvent] = []

    func append(_ event: ScanEvent) {
        events.append(event)
    }

    /// Polls until `predicate` holds (or the deadline passes) and returns
    /// the events seen so far. Tests assert on the returned slice so a
    /// timeout surfaces as a normal expectation failure, never a hang.
    func waitUntil(
        timeout: Duration = .seconds(15),
        _ predicate: @Sendable ([ScanEvent]) -> Bool
    ) async -> [ScanEvent] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(events) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events
    }
}

private func collectEvents(of engine: ScanEngine) -> EventBox {
    let box = EventBox()
    Task {
        for await event in engine.events {
            await box.append(event)
        }
    }
    return box
}

private func finishedSnapshots(_ events: [ScanEvent]) -> [(CategoryID, CategorySnapshot)] {
    events.compactMap { event -> (CategoryID, CategorySnapshot)? in
        if case .finished(let id, let snapshot) = event { return (id, snapshot) } else { return nil }
    }
}

// MARK: - Protected paths that must survive every clean

/// Canonical-fixture protected paths (relative to the fixture root). The
/// simulator device is visible in totals, but no clean path may remove it.
private let decoyPaths = [
    "Library/Developer/CoreSimulator/Devices/8A1B2C3D-0000-4444-8888-CAFEBABED00D/data/Documents/precious.txt",
    "Library/Developer/CoreSimulator/Devices/uuid/device.plist",
    "Library/Developer/Xcode/iOS DeviceSupport/whatever/Symbols/sym.bin",
    "Documents/Repositories/NoMarker/build/payload.o",
    ".gradle/wrapper/dists/gradle-8.7-bin/abc123/gradle-8.7-bin.zip",
    ".gradle/gradle.properties",
    ".npm/_logs/2026-06-12T00_00_00_000Z-debug-0.log",
    ".npmrc",
    "Library/Caches/com.apple.somethingelse/Cache.db",
    "Library/pnpm/global/5/package.json",
    "Library/Developer/XcodeBuildMCP/config.json",
    "Library/Developer/XcodeBuildMCP/config/settings.json",
]

// MARK: - Clean All end to end

@Test func cleanAllFromScannedSnapshotsDeletesPlannedItemsSparesDecoysAndArchives() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    // Bulk payload so the statfs freed-bytes delta dwarfs unrelated volume
    // churn during the test run.
    try fixture.plantFile(
        "\(FixtureHome.derivedDataPath)/DemoApp-abcdefgh/Build/big.bin", bytes: 32 * 1024 * 1024)

    let context = ScanContext(home: fixture.root)
    let store = StatsStore(fileURL: fixture.url("stats.json"), debounceInterval: .milliseconds(10))
    let engine = ScanEngine(
        sources: SourceRegistry.allSources,
        context: context,
        deleter: try SafeDeleter(home: fixture.root, mode: .live),
        statsStore: store
    )
    let box = collectEvents(of: engine)

    await engine.refresh(trigger: .manual)
    let allIDs = SourceRegistry.allSources.map(\.id)
    let preCleanEvents = await box.waitUntil { finishedSnapshots($0).count == allIDs.count }
    let preCleanCount = preCleanEvents.count
    let snapshots = finishedSnapshots(preCleanEvents).map(\.1)
    #expect(snapshots.count == allIDs.count)

    // Clean All plan with empty user include/exclude (settings are Phase 6):
    // the destructive Archives category and view-only simulator data must
    // stay out.
    let archives = CategoryID("xcode-archives")
    let simulatorData = CategoryID("simulator-device-data")
    let plan = CleanPlanner(sources: SourceRegistry.allSources).planCleanAll(snapshots: snapshots)
    #expect(!plan.itemsByCategory.keys.contains(archives))
    #expect(!plan.itemsByCategory.keys.contains(simulatorData))
    #expect(Set(plan.itemsByCategory.keys) == Set(allIDs).subtracting([archives, simulatorData]))
    #expect(plan.estimatedBytes > 0)

    // MenuState mirrors the GUI: painted from the scanned snapshots.
    var menuState = MenuState(sources: SourceRegistry.allSources, persisted: snapshots)
    let archivesBytes = try #require(snapshots.first { $0.categoryID == archives }).totalBytes
    let simulatorBytes = try #require(
        snapshots.first { $0.categoryID == simulatorData }).totalBytes
    let protectedBytes = archivesBytes + simulatorBytes
    #expect(simulatorBytes > 0)
    #expect(menuState.displayedTotalBytes > protectedBytes)

    var freedBytes: Int64 = 0
    var deletedPaths: [String] = []
    for source in SourceRegistry.allSources {
        guard let items = plan.itemsByCategory[source.id] else { continue }
        let outcome = try await engine.clean(category: source.id, items: items)
        freedBytes += outcome.freedBytes
        deletedPaths += outcome.deletedPaths
        menuState.noteCleaned(source.id)
    }
    #expect(freedBytes > 0)
    #expect(!deletedPaths.isEmpty)

    // Every planned item left the disk; `.contentsOnly` roots survive empty.
    for (id, items) in plan.itemsByCategory {
        for item in items {
            let path = item.url.path(percentEncoded: false)
            switch item.deletionMode {
            case .entireItem:
                #expect(
                    !FileManager.default.fileExists(atPath: path),
                    "\(id): \(path) should be deleted")
            case .contentsOnly:
                #expect(
                    FileManager.default.fileExists(atPath: path),
                    "\(id): root \(path) must survive a contentsOnly clean")
                let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                #expect(children.isEmpty, "\(id): \(path) should be emptied, found \(children)")
            }
        }
    }

    // Every protected path survives, and the unplanned Archives stay intact.
    for decoy in decoyPaths {
        #expect(fixture.exists(decoy), "decoy \(decoy) must survive Clean All")
    }
    #expect(fixture.exists("\(FixtureHome.archivesRootPath)/2026-06-01/DemoApp 1.0.xcarchive"))
    #expect(fixture.exists("\(FixtureHome.archivesRootPath)/RootArchive.xcarchive"))
    // The third archive (planted by plantDerivedDataDecoys as a derived-data
    // decoy, but a REAL archive item to this category) survives too — all
    // three Archives items must outlive a default Clean All.
    #expect(fixture.exists("\(FixtureHome.archivesRootPath)/x.xcarchive"))

    // noteCleaned dropped the cleaned rows' numbers immediately: the total
    // shows only the uncleaned Archives and simulator data, never a stale
    // pre-clean value.
    let cleanedIDs = Set(plan.itemsByCategory.keys)
    #expect(menuState.displayedTotalBytes == protectedBytes)

    // Apply the engine's automatic .postClean rescan events in stream order;
    // a cleaned row must never repaint a stale (nonzero) value on the way to
    // its confirmed zero.
    let allEvents = await box.waitUntil { events in
        let post = finishedSnapshots(Array(events.dropFirst(preCleanCount)))
        return cleanedIDs.isSubset(of: Set(post.map(\.0)))
    }
    for event in allEvents.dropFirst(preCleanCount) {
        menuState.apply(event)
        for row in menuState.rows where cleanedIDs.contains(row.id) {
            #expect((row.bytes ?? 0) == 0, "\(row.id): stale bytes repainted mid-postClean")
        }
        #expect(menuState.displayedTotalBytes <= protectedBytes)
    }
    let postClean = finishedSnapshots(Array(allEvents.dropFirst(preCleanCount)))
        .filter { cleanedIDs.contains($0.0) }
    #expect(postClean.allSatisfy { $0.1.totalBytes == 0 })
    for row in menuState.rows where cleanedIDs.contains(row.id) {
        #expect(row.bytes == 0, "\(row.id): postClean rescan should confirm zero bytes")
    }
}

// MARK: - Per-category clean of the destructive Archives

@Test func perCategoryArchivesCleanCarriesDestructiveWarningAndDeletes() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()

    let engine = ScanEngine(
        sources: SourceRegistry.allSources,
        context: ScanContext(home: fixture.root),
        deleter: try SafeDeleter(home: fixture.root, mode: .live)
    )
    let box = collectEvents(of: engine)
    let archives = CategoryID("xcode-archives")

    await engine.refresh(categories: [archives], trigger: .manual)
    let events = await box.waitUntil { finishedSnapshots($0).count == 1 }
    let snapshots = finishedSnapshots(events).map(\.1)

    let plan = CleanPlanner(sources: SourceRegistry.allSources)
        .planCategory(archives, snapshots: snapshots)
    let items = try #require(plan.itemsByCategory[archives])
    #expect(items.count == FixtureHome.canonicalExpectedItemCounts["xcode-archives"])
    #expect(plan.warnings.contains(CleanPlanner.destructiveWarning))

    let outcome = try await engine.clean(category: archives, items: items)
    #expect(outcome.deletedPaths.count == items.count)
    for item in items {
        #expect(!FileManager.default.fileExists(atPath: item.url.path(percentEncoded: false)))
    }
    // The Archives root itself and its sibling decoy survive.
    #expect(fixture.exists(FixtureHome.archivesRootPath))
    #expect(fixture.exists("Library/Developer/Xcode/iOS DeviceSupport/whatever/Symbols/sym.bin"))
}

// MARK: - Clean re-entry and error surfacing

/// Deleter whose deletions park until `open()` — holds a clean in its
/// `.cleaning` state so the re-entry interlock is observable.
private actor ParkedDeleter: ItemDeleting {
    private(set) var calls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func delete(_ request: DeletionRequest) async throws -> [URL] {
        calls += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return [request.item.url]
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func waitForCalls(_ target: Int, timeout: Duration = .seconds(10)) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while calls < target && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return calls
    }
}

@Test func secondCleanOfACategoryWhileOneRunsThrowsCleanAlreadyRunning() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDerivedDataRoot()
    try fixture.plantDerivedDataProject("DemoApp-abcdefgh")

    let deleter = ParkedDeleter()
    let engine = ScanEngine(
        sources: [DerivedDataSource()],
        context: ScanContext(home: fixture.root),
        deleter: deleter
    )

    let first = Task { try await engine.clean(category: DerivedDataSource.id) }
    #expect(await deleter.waitForCalls(1) == 1)

    // The model layer never gets here (confirmPendingClean is guarded by
    // isCleaning), but if anything raced past it the engine refuses.
    await #expect(throws: ScanEngineError.cleanAlreadyRunning(DerivedDataSource.id)) {
        try await engine.clean(category: DerivedDataSource.id)
    }

    await deleter.open()
    let outcome = try await first.value
    #expect(outcome.deletedPaths.count == 1)
}

@Test func cleanSurfacesSafeDeleterErrorsAndTheEngineRecovers() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDerivedDataRoot()
    try fixture.plantDerivedDataProject("DemoApp-abcdefgh")

    let engine = ScanEngine(
        sources: [DerivedDataSource()],
        context: ScanContext(home: fixture.root),
        deleter: try SafeDeleter(home: fixture.root, mode: .live)
    )

    // An item that no longer exists on disk: SafeDeleter refuses, the error
    // propagates out of engine.clean (this is the message the GUI surfaces).
    let ghost = CacheItem(
        categoryID: DerivedDataSource.id,
        url: fixture.url("\(FixtureHome.derivedDataPath)/Ghost-zzzzzzzz"),
        label: "Ghost-zzzzzzzz")
    await #expect(throws: SafeDeleterError.self) {
        try await engine.clean(category: DerivedDataSource.id, items: [ghost])
    }

    // The error path reset the category's state machine: a follow-up clean
    // of the real item succeeds.
    let outcome = try await engine.clean(category: DerivedDataSource.id)
    #expect(outcome.deletedPaths.count == 1)
    #expect(!fixture.exists("\(FixtureHome.derivedDataPath)/DemoApp-abcdefgh"))
}
