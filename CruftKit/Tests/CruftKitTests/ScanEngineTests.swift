import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

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

private func categoryID(of event: ScanEvent) -> CategoryID {
    switch event {
    case .categoryStarted(let id): return id
    case .discovered(let id, _): return id
    case .partial(let id, _): return id
    case .finished(let id, _): return id
    case .deferred(let id, _): return id
    case .failed(let id, _): return id
    }
}

private func startedCategories(_ events: [ScanEvent]) -> [CategoryID] {
    events.compactMap { event -> CategoryID? in
        if case .categoryStarted(let id) = event { return id } else { return nil }
    }
}

private func discoveredItems(_ events: [ScanEvent]) -> [CategoryID: [CacheItem]] {
    var result: [CategoryID: [CacheItem]] = [:]
    for case .discovered(let id, let items) in events { result[id] = items }
    return result
}

private func finishedSnapshots(_ events: [ScanEvent]) -> [(CategoryID, CategorySnapshot)] {
    events.compactMap { event -> (CategoryID, CategorySnapshot)? in
        if case .finished(let id, let snapshot) = event { return (id, snapshot) } else { return nil }
    }
}

private func deferrals(_ events: [ScanEvent]) -> [(CategoryID, DeferralReason)] {
    events.compactMap { event -> (CategoryID, DeferralReason)? in
        if case .deferred(let id, let reason) = event { return (id, reason) } else { return nil }
    }
}

private func failures(_ events: [ScanEvent]) -> [(CategoryID, String)] {
    events.compactMap { event -> (CategoryID, String)? in
        if case .failed(let id, let message) = event { return (id, message) } else { return nil }
    }
}

// MARK: - Timing-sensitive test doubles

/// One-item source whose "cache" never has to exist on disk — the gated
/// measurer below never touches it.
private struct FakeCacheSource: CacheSource {
    static let id = CategoryID("fake-cache")
    let displayName = "Fake Cache"

    func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: "fake-root")]
    }

    func discover(context: ScanContext) async throws -> [CacheItem] {
        [CacheItem(
            categoryID: Self.id,
            url: context.home.appending(path: "fake-root/payload"),
            label: "payload")]
    }
}

/// Measurer whose walks park until `open()` — and never return at all if it
/// is never opened (the watchdog's "blocked syscall on a dead mount").
private actor GatedMeasurer: DirectoryMeasurer {
    private(set) var calls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func measure(
        _ root: URL,
        partial: @Sendable (ItemSize) -> Void
    ) async throws -> ItemSize {
        calls += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return ItemSize(allocatedBytes: 4096, fileCount: 1)
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

private func makeFakeEngine(
    home: URL,
    measurer: GatedMeasurer,
    watchdogTimeout: Duration = .seconds(60)
) -> ScanEngine {
    ScanEngine(
        sources: [FakeCacheSource()],
        context: ScanContext(home: home),
        measurer: measurer,
        deleter: RecordingDeleter(),
        statsStore: nil,
        quietWindow: 180,
        watchdogTimeout: watchdogTimeout
    )
}

// MARK: - Full scan over the canonical fixture

@Test func fullScanEmitsStartedDiscoveredFinishedForAllCategoriesAndPersistsStats() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let context = ScanContext(home: fixture.root)
    let store = StatsStore(fileURL: fixture.url("stats.json"), debounceInterval: .milliseconds(10))
    let engine = ScanEngine(
        sources: SourceRegistry.allSources,
        context: context,
        deleter: RecordingDeleter(),
        statsStore: store
    )
    let box = collectEvents(of: engine)

    await engine.refresh(trigger: .manual)
    let allIDs = SourceRegistry.allSources.map(\.id)
    let events = await box.waitUntil { finishedSnapshots($0).count == allIDs.count }

    #expect(Set(startedCategories(events)) == Set(allIDs))
    #expect(failures(events).isEmpty)
    #expect(deferrals(events).isEmpty)

    let discovered = discoveredItems(events)
    for id in allIDs {
        #expect(
            discovered[id]?.count == FixtureHome.canonicalExpectedItemCounts[id.rawValue],
            "\(id): wrong discovered item count")
    }

    let finished = finishedSnapshots(events)
    #expect(finished.count == allIDs.count)
    for (id, snapshot) in finished {
        #expect(snapshot.totalBytes > 0, "\(id) finished with zero bytes")
        #expect(snapshot.updatedAt != nil, "\(id) finished without updatedAt")
        #expect(snapshot.items.count == FixtureHome.canonicalExpectedItemCounts[id.rawValue])
    }

    await store.flush()
    let persisted = await StatsStore(fileURL: fixture.url("stats.json")).load()
    #expect(Set(persisted.map(\.categoryID)) == Set(allIDs))
    #expect(persisted.allSatisfy { $0.totalBytes > 0 && $0.updatedAt != nil })
}

// MARK: - Dedup and postClean

@Test func concurrentRefreshesOfOneCategoryRunExactlyOneWalker() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let measurer = GatedMeasurer()
    let engine = makeFakeEngine(home: fixture.root, measurer: measurer)
    let box = collectEvents(of: engine)

    await engine.refresh(categories: [FakeCacheSource.id], trigger: .menuOpened)
    await engine.refresh(categories: [FakeCacheSource.id], trigger: .manual)
    #expect(await measurer.waitForCalls(1) == 1)

    await measurer.open()
    let events = await box.waitUntil { finishedSnapshots($0).count == 1 }
    #expect(startedCategories(events).count == 1)
    #expect(finishedSnapshots(events).count == 1)
    #expect(await measurer.calls == 1)
}

@Test func postCleanTriggerNeverDedupsAgainstAnInFlightScan() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let measurer = GatedMeasurer()
    let engine = makeFakeEngine(home: fixture.root, measurer: measurer)
    let box = collectEvents(of: engine)

    await engine.refresh(categories: [FakeCacheSource.id], trigger: .manual)
    #expect(await measurer.waitForCalls(1) == 1)

    // .postClean cancels-and-restarts: a second walker must run.
    await engine.refresh(categories: [FakeCacheSource.id], trigger: .postClean)
    #expect(await measurer.waitForCalls(2) == 2)

    await measurer.open()
    _ = await box.waitUntil { finishedSnapshots($0).count >= 1 }
    // The cancelled first walker resumes too; give its (dropped) events a
    // beat to prove they never arrive.
    try await Task.sleep(for: .milliseconds(150))
    let events = await box.waitUntil { _ in true }
    #expect(finishedSnapshots(events).count == 1)
    #expect(startedCategories(events).count == 2)
}

// MARK: - Clean interlock

@Test func cleanDuringScanCancelsItAndPostCleanRescanReportsFreedSpace() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    // Bulk so the in-flight walk outlives the clean call and the statfs
    // delta dwarfs unrelated volume churn.
    try fixture.plantFile(
        "\(FixtureHome.derivedDataPath)/DemoApp-abcdefgh/Build/big.bin", bytes: 16 * 1024 * 1024)
    for index in 0..<1200 {
        try fixture.plantFile(
            "\(FixtureHome.derivedDataPath)/OtherApp-ijklmnop/Index/d\(index % 12)/f\(index).bin",
            bytes: 4096)
    }
    let context = ScanContext(home: fixture.root)
    let store = StatsStore(fileURL: fixture.url("stats.json"), debounceInterval: .milliseconds(10))
    let engine = ScanEngine(
        sources: SourceRegistry.allSources,
        context: context,
        deleter: try SafeDeleter(home: fixture.root, mode: .live),
        statsStore: store
    )
    let box = collectEvents(of: engine)

    await engine.refresh(categories: [DerivedDataSource.id], trigger: .manual)
    let outcome = try await engine.clean(category: DerivedDataSource.id)

    #expect(outcome.deletedPaths.count == 3)
    #expect(outcome.freedBytes > 0)
    #expect(!fixture.exists("\(FixtureHome.derivedDataPath)/DemoApp-abcdefgh"))
    #expect(!fixture.exists("\(FixtureHome.derivedDataPath)/OtherApp-ijklmnop"))
    #expect(fixture.exists(FixtureHome.derivedDataPath))

    // The automatic .postClean rescan reports the updated (empty) state;
    // the cancelled pre-clean walk's stale totals were dropped.
    let events = await box.waitUntil { events in
        finishedSnapshots(events).contains { $0.0 == DerivedDataSource.id }
    }
    let finished = finishedSnapshots(events).filter { $0.0 == DerivedDataSource.id }
    #expect(finished.count == 1)
    #expect(finished.allSatisfy { $0.1.items.isEmpty && $0.1.totalBytes == 0 })
}

// MARK: - Quiet gate

@Test func quietGateDefersScheduledScansOfRecentlyModifiedRoots() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDerivedDataRoot()
    try fixture.plantDerivedDataProject("DemoApp-abcdefgh")
    let engine = ScanEngine(
        sources: [DerivedDataSource()],
        context: ScanContext(home: fixture.root),
        measurer: FoundationMeasurer(),
        deleter: RecordingDeleter(),
        statsStore: nil,
        quietWindow: 180,
        watchdogTimeout: .seconds(60)
    )
    let box = collectEvents(of: engine)

    // The fixture was planted moments ago: every mtime is inside the window.
    await engine.refresh(categories: [DerivedDataSource.id], trigger: .scheduled)
    let events = await box.waitUntil { !deferrals($0).isEmpty }
    #expect(deferrals(events).map(\.1) == [.buildActivityDetected])
    #expect(finishedSnapshots(events).isEmpty)
}

@Test func quietGateDoesNotApplyToManualTriggersOrOutsideTheWindow() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDerivedDataRoot()
    try fixture.plantDerivedDataProject("DemoApp-abcdefgh")

    func makeEngine(quietWindow: TimeInterval) -> ScanEngine {
        ScanEngine(
            sources: [DerivedDataSource()],
            context: ScanContext(home: fixture.root),
            measurer: FoundationMeasurer(),
            deleter: RecordingDeleter(),
            statsStore: nil,
            quietWindow: quietWindow,
            watchdogTimeout: .seconds(60)
        )
    }

    // Same fresh mtimes, manual trigger: proceeds.
    let manualEngine = makeEngine(quietWindow: 180)
    let manualBox = collectEvents(of: manualEngine)
    await manualEngine.refresh(categories: [DerivedDataSource.id], trigger: .manual)
    let manualEvents = await manualBox.waitUntil { !finishedSnapshots($0).isEmpty }
    #expect(deferrals(manualEvents).isEmpty)
    #expect(finishedSnapshots(manualEvents).count == 1)

    // Scheduled trigger with the window shrunk to zero: proceeds.
    let openEngine = makeEngine(quietWindow: 0)
    let openBox = collectEvents(of: openEngine)
    await openEngine.refresh(categories: [DerivedDataSource.id], trigger: .scheduled)
    let openEvents = await openBox.waitUntil { !finishedSnapshots($0).isEmpty }
    #expect(deferrals(openEvents).isEmpty)
    #expect(finishedSnapshots(openEvents).count == 1)
}

// MARK: - Generations

@Test func invalidateAndRescanDropsTheStaleWalkersEvents() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let measurer = GatedMeasurer()
    let engine = makeFakeEngine(home: fixture.root, measurer: measurer)
    let box = collectEvents(of: engine)

    await engine.refresh(categories: [FakeCacheSource.id], trigger: .manual)
    #expect(await measurer.waitForCalls(1) == 1)

    await engine.invalidateAndRescan(categories: [FakeCacheSource.id])
    #expect(await measurer.waitForCalls(2) == 2)

    await measurer.open()
    _ = await box.waitUntil { finishedSnapshots($0).count >= 1 }
    try await Task.sleep(for: .milliseconds(150))
    let events = await box.waitUntil { _ in true }
    // Both walkers resumed, but only the post-invalidation generation may
    // speak: exactly one finished, zero failures.
    #expect(finishedSnapshots(events).count == 1)
    #expect(failures(events).isEmpty)
    #expect(startedCategories(events).count == 2)
}

// MARK: - Exclusions

@Test func excludedCategoriesAreNeverScanned() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()
    let excluded = GradleSource.id
    let context = ScanContext(home: fixture.root, excludedSourceIDs: [excluded])
    let engine = ScanEngine(
        sources: SourceRegistry.allSources,
        context: context,
        deleter: RecordingDeleter()
    )
    let box = collectEvents(of: engine)

    await engine.refresh(trigger: .manual)
    // Asking for the excluded category by name is refused too.
    await engine.refresh(categories: [excluded], trigger: .manual)

    let expectedCount = SourceRegistry.allSources.count - 1
    let events = await box.waitUntil { finishedSnapshots($0).count == expectedCount }
    #expect(finishedSnapshots(events).count == expectedCount)
    #expect(events.allSatisfy { categoryID(of: $0) != excluded })
}

// MARK: - Watchdog

@Test func watchdogFailsAStalledCategoryAndFreesItForRescan() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let measurer = GatedMeasurer()
    let engine = makeFakeEngine(
        home: fixture.root, measurer: measurer, watchdogTimeout: .milliseconds(200))
    let box = collectEvents(of: engine)

    await engine.refresh(categories: [FakeCacheSource.id], trigger: .manual)
    let events = await box.waitUntil { !failures($0).isEmpty }
    #expect(failures(events).map(\.1) == ["stalled"])
    #expect(finishedSnapshots(events).isEmpty)

    // The stalled walker was abandoned, not awaited: the category is idle
    // again and a new walker starts immediately.
    await engine.refresh(categories: [FakeCacheSource.id], trigger: .manual)
    let rescanEvents = await box.waitUntil { startedCategories($0).count == 2 }
    #expect(startedCategories(rescanEvents).count == 2)
    #expect(await measurer.waitForCalls(2) == 2)

    // Release the parked fake walks so no continuation leaks.
    await measurer.open()
}

// MARK: - Permission denial

@Test func unreadableExistingRootDefersWithPermissionDenied() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDerivedDataRoot()
    try fixture.plantDerivedDataProject("DemoApp-abcdefgh")
    let rootPath = fixture.url(FixtureHome.derivedDataPath).path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rootPath)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootPath)
    }

    let engine = ScanEngine(
        sources: [DerivedDataSource()],
        context: ScanContext(home: fixture.root),
        deleter: RecordingDeleter()
    )
    let box = collectEvents(of: engine)
    await engine.refresh(categories: [DerivedDataSource.id], trigger: .manual)

    let events = await box.waitUntil { !deferrals($0).isEmpty }
    #expect(deferrals(events).map(\.1) == [.permissionDenied])
    #expect(finishedSnapshots(events).isEmpty)
    #expect(failures(events).isEmpty)
}
