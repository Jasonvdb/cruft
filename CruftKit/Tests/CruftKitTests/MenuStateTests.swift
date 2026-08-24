import Foundation
import Testing
@testable import CruftKit

// MARK: - Fixtures

// MenuState only reads source metadata. One type per id because
// `CacheSource.id` is a STATIC requirement — the instance `id` accessor in
// the protocol extension always returns `Self.id`.
private struct SourceA: CacheSource {
    static let id = CategoryID("a")
    let displayName = "A"
    func allowedDeletionRoots(context: ScanContext) -> [URL] { [] }
    func discover(context: ScanContext) async throws -> [CacheItem] { [] }
}

private struct SourceB: CacheSource {
    static let id = CategoryID("b")
    let displayName = "B"
    func allowedDeletionRoots(context: ScanContext) -> [URL] { [] }
    func discover(context: ScanContext) async throws -> [CacheItem] { [] }
}

private struct SourceC: CacheSource {
    static let id = CategoryID("c")
    let displayName = "C"
    let supportsCleaning = false
    func allowedDeletionRoots(context: ScanContext) -> [URL] { [] }
    func discover(context: ScanContext) async throws -> [CacheItem] { [] }
}

private func makeSnapshot(
    _ id: String, bytes: Int64, itemCount: Int = 1, updatedAt: Date? = Date()
) -> CategorySnapshot {
    let items = (0..<itemCount).map { index in
        MeasuredItem(
            item: CacheItem(
                categoryID: CategoryID(id),
                url: URL(filePath: "/tmp/fixture/\(id)/cache/entry-\(index)"),
                label: "entry-\(index)"
            ),
            size: ItemSize(allocatedBytes: bytes / Int64(itemCount), fileCount: 1)
        )
    }
    return CategorySnapshot(categoryID: CategoryID(id), items: items, updatedAt: updatedAt)
}

private func row(_ state: MenuState, _ id: String) -> MenuState.Row? {
    state.rows.first { $0.id == CategoryID(id) }
}

// MARK: - Initial paint

@Test func persistedSnapshotsPaintInitialValuesWithUpdatedAt() {
    let updatedAt = Date(timeIntervalSinceNow: -600)
    let state = MenuState(
        sources: [SourceA(), SourceB()],
        persisted: [makeSnapshot("a", bytes: 8192, itemCount: 2, updatedAt: updatedAt)]
    )

    let painted = row(state, "a")
    #expect(painted?.bytes == 8192)
    #expect(painted?.itemCount == 2)
    #expect(painted?.activity == .idle(updatedAt: updatedAt))

    let unpainted = row(state, "b")
    #expect(unpainted?.bytes == nil)
    #expect(unpainted?.itemCount == nil)
    #expect(unpainted?.activity == .idle(updatedAt: nil))

    #expect(state.displayedTotalBytes == 8192)
}

@Test func rowsFollowRegistryOrderNotPersistedOrder() {
    let sources = SourceRegistry.allSources
    // Persisted snapshots arrive sorted by id (StatsStore.load contract) —
    // rows must still follow registry order, with registry metadata.
    let persisted = sources.map(\.id.rawValue).sorted().map { makeSnapshot($0, bytes: 4096) }
    let state = MenuState(sources: sources, persisted: persisted)

    #expect(state.rows.map(\.id) == sources.map(\.id))
    #expect(state.rows.map(\.displayName) == sources.map(\.displayName))
    #expect(state.rows.map(\.isDestructive) == sources.map(\.isDestructive))
    #expect(state.rows.map(\.supportsCleaning) == sources.map(\.supportsCleaning))
    #expect(state.rows.allSatisfy { $0.bytes == 4096 })
}

@Test func rowPreservesViewOnlyCapability() {
    let state = MenuState(sources: [SourceA(), SourceC()], persisted: [])

    #expect(row(state, "a")?.supportsCleaning == true)
    #expect(row(state, "c")?.supportsCleaning == false)
}

// MARK: - The retention rule

@Test func partialDoesNotShrinkPriorFinal() {
    var state = MenuState(
        sources: [SourceA()],
        persisted: [makeSnapshot("a", bytes: 100_000)]
    )

    state.apply(.categoryStarted(CategoryID("a")))
    #expect(row(state, "a")?.bytes == 100_000)
    #expect(row(state, "a")?.activity == .discovering)

    state.apply(.discovered(CategoryID("a"), items: makeSnapshot("a", bytes: 0, itemCount: 3).items.map(\.item)))
    #expect(row(state, "a")?.bytes == 100_000)
    #expect(row(state, "a")?.itemCount == 1, "discovered must not replace a final-backed count")

    state.apply(.partial(CategoryID("a"), makeSnapshot("a", bytes: 4096, updatedAt: nil)))
    #expect(row(state, "a")?.bytes == 100_000, "a rescan partial must never shrink the displayed number")
    #expect(row(state, "a")?.activity == .sizing)
    #expect(state.displayedTotalBytes == 100_000)
}

@Test func partialDrivesNumberWhenNoPriorExists() {
    var state = MenuState(sources: [SourceA()], persisted: [])

    state.apply(.categoryStarted(CategoryID("a")))
    state.apply(.discovered(CategoryID("a"), items: makeSnapshot("a", bytes: 0, itemCount: 3).items.map(\.item)))
    #expect(row(state, "a")?.itemCount == 3, "first scan shows the discovered count immediately")

    state.apply(.partial(CategoryID("a"), makeSnapshot("a", bytes: 4096, updatedAt: nil)))
    #expect(row(state, "a")?.bytes == 4096)

    state.apply(.partial(CategoryID("a"), makeSnapshot("a", bytes: 12_288, updatedAt: nil)))
    #expect(row(state, "a")?.bytes == 12_288)
    #expect(row(state, "a")?.activity == .sizing)
}

@Test func finishedSwapsAtomically() {
    var state = MenuState(
        sources: [SourceA()],
        persisted: [makeSnapshot("a", bytes: 100_000, itemCount: 4)]
    )
    let updatedAt = Date()

    state.apply(.categoryStarted(CategoryID("a")))
    state.apply(.partial(CategoryID("a"), makeSnapshot("a", bytes: 4096, updatedAt: nil)))
    state.apply(.finished(CategoryID("a"), makeSnapshot("a", bytes: 60_000, itemCount: 2, updatedAt: updatedAt)))

    let swapped = row(state, "a")
    #expect(swapped?.bytes == 60_000)
    #expect(swapped?.itemCount == 2)
    #expect(swapped?.activity == .idle(updatedAt: updatedAt))
    #expect(state.displayedTotalBytes == 60_000)
}

@Test func deferredAndFailedKeepThePreviousNumberWithAStatus() {
    var state = MenuState(
        sources: [SourceA(), SourceB()],
        persisted: [
            makeSnapshot("a", bytes: 100_000, itemCount: 4),
            makeSnapshot("b", bytes: 50_000),
        ]
    )

    state.apply(.categoryStarted(CategoryID("a")))
    state.apply(.deferred(CategoryID("a"), reason: .permissionDenied))
    let deferred = row(state, "a")
    #expect(deferred?.bytes == 100_000)
    #expect(deferred?.itemCount == 4)
    #expect(deferred?.activity == .deferred(.permissionDenied))

    state.apply(.categoryStarted(CategoryID("b")))
    state.apply(.failed(CategoryID("b"), message: "stalled"))
    let failed = row(state, "b")
    #expect(failed?.bytes == 50_000)
    #expect(failed?.activity == .failed("stalled"))

    #expect(state.displayedTotalBytes == 150_000)
}

@Test func totalNeverDipsAcrossAScriptedRescan() {
    var state = MenuState(
        sources: [SourceA(), SourceB(), SourceC()],
        persisted: [
            makeSnapshot("a", bytes: 100_000),
            makeSnapshot("b", bytes: 50_000),
            // "c" has no persisted value: first-launch path for that row.
        ]
    )
    let script: [ScanEvent] = [
        .categoryStarted(CategoryID("a")),
        .categoryStarted(CategoryID("b")),
        .categoryStarted(CategoryID("c")),
        .partial(CategoryID("a"), makeSnapshot("a", bytes: 4096, updatedAt: nil)),
        .partial(CategoryID("c"), makeSnapshot("c", bytes: 8192, updatedAt: nil)),
        .partial(CategoryID("b"), makeSnapshot("b", bytes: 12_288, updatedAt: nil)),
        .partial(CategoryID("c"), makeSnapshot("c", bytes: 20_480, updatedAt: nil)),
        .finished(CategoryID("a"), makeSnapshot("a", bytes: 110_000)),
        .partial(CategoryID("b"), makeSnapshot("b", bytes: 40_960, updatedAt: nil)),
        .finished(CategoryID("c"), makeSnapshot("c", bytes: 30_000)),
        .finished(CategoryID("b"), makeSnapshot("b", bytes: 50_000)),
    ]

    var previousTotal = state.displayedTotalBytes
    #expect(previousTotal == 150_000)
    for event in script {
        state.apply(event)
        let total = state.displayedTotalBytes
        #expect(total >= previousTotal, "total dipped applying \(event)")
        previousTotal = total
    }
    #expect(previousTotal == 190_000)
}

@Test func unknownCategoryEventsAreIgnored() {
    var state = MenuState(
        sources: [SourceA()],
        persisted: [makeSnapshot("a", bytes: 8192)]
    )
    state.apply(.finished(CategoryID("ghost"), makeSnapshot("ghost", bytes: 4096)))
    #expect(state.rows.count == 1)
    #expect(state.displayedTotalBytes == 8192)
}

@Test func noteCleanedDropsTheFinalSoPostCleanPartialsDrive() {
    var state = MenuState(
        sources: [SourceA()],
        persisted: [makeSnapshot("a", bytes: 100_000)]
    )

    state.noteCleaned(CategoryID("a"))
    #expect(row(state, "a")?.bytes == nil)
    #expect(row(state, "a")?.itemCount == nil)

    state.apply(.categoryStarted(CategoryID("a")))
    state.apply(.partial(CategoryID("a"), makeSnapshot("a", bytes: 4096, updatedAt: nil)))
    #expect(row(state, "a")?.bytes == 4096, "post-clean partials drive the number again")
}
