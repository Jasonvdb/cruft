import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private func makeSnapshot(
    _ id: String, bytes: Int64, fileCount: Int = 1, updatedAt: Date? = Date()
) -> CategorySnapshot {
    let item = CacheItem(
        categoryID: CategoryID(id),
        url: URL(filePath: "/tmp/fixture/\(id)/cache/entry"),
        label: id
    )
    return CategorySnapshot(
        categoryID: CategoryID(id),
        items: [MeasuredItem(item: item, size: ItemSize(allocatedBytes: bytes, fileCount: fileCount))],
        updatedAt: updatedAt
    )
}

private func statsFileExists(_ fixture: FixtureHome) -> Bool {
    fixture.exists("stats/stats.json")
}

private func statsFileURL(_ fixture: FixtureHome) -> URL {
    fixture.url("stats/stats.json")
}

@Test func loadOnMissingFileReturnsEmptyWithoutCreatingIt() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    #expect(await store.load().isEmpty)
    #expect(!statsFileExists(fixture))
}

@Test func roundTripPersistsSnapshotsWithISO8601Dates() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let updatedAt = Date()

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    await store.update(makeSnapshot("derived-data", bytes: 8192, fileCount: 2, updatedAt: updatedAt))
    await store.update(makeSnapshot("gradle", bytes: 4096, updatedAt: updatedAt))
    await store.flush()

    let raw = try String(contentsOf: statsFileURL(fixture), encoding: .utf8)
    #expect(raw.contains("\"schemaVersion\":1"))

    let reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    #expect(reloaded.map(\.categoryID.rawValue) == ["derived-data", "gradle"])
    #expect(reloaded[0].totalBytes == 8192)
    #expect(reloaded[0].fileCount == 2)
    #expect(reloaded[1].totalBytes == 4096)
    let persistedDate = try #require(reloaded[0].updatedAt)
    // ISO-8601 keeps whole seconds only.
    #expect(abs(persistedDate.timeIntervalSince(updatedAt)) < 1.0)
}

@Test func corruptFileLoadsEmptyAndStoreStaysUsable() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDir("stats")
    try Data("{ definitely not stats".utf8).write(to: statsFileURL(fixture))

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    #expect(await store.load().isEmpty)

    // The corrupt file was reset to an empty, valid, current-schema file
    // (atomic overwrite — file deletion lives only in SafeDeleter).
    let resetData = try Data(contentsOf: statsFileURL(fixture))
    let reset = try JSONDecoder().decode(StatsStore.PersistedStats.self, from: resetData)
    #expect(reset.schemaVersion == StatsStore.currentSchemaVersion)
    #expect(reset.categories.isEmpty)

    await store.update(makeSnapshot("js-cache", bytes: 4096))
    await store.flush()
    let reloaded = await store.load()
    #expect(reloaded.map(\.categoryID.rawValue) == ["js-cache"])
}

@Test func unknownSchemaVersionIsTreatedAsCorrupt() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantDir("stats")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let future = StatsStore.PersistedStats(
        schemaVersion: StatsStore.currentSchemaVersion + 1,
        categories: ["gradle": makeSnapshot("gradle", bytes: 4096)]
    )
    try encoder.encode(future).write(to: statsFileURL(fixture))

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    #expect(await store.load().isEmpty)
    let resetData = try Data(contentsOf: statsFileURL(fixture))
    let reset = try JSONDecoder().decode(StatsStore.PersistedStats.self, from: resetData)
    #expect(reset.schemaVersion == StatsStore.currentSchemaVersion)
    #expect(reset.categories.isEmpty)
}

@Test func debounceCoalescesTwoUpdatesIntoOneWrite() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(150))
    await store.update(makeSnapshot("derived-data", bytes: 8192))
    await store.update(makeSnapshot("gradle", bytes: 4096))
    // Inside the debounce window nothing has been written yet.
    #expect(!statsFileExists(fixture))

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while !statsFileExists(fixture) && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(statsFileExists(fixture))

    // The single coalesced write carries BOTH updates…
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let stats = try decoder.decode(
        StatsStore.PersistedStats.self, from: Data(contentsOf: statsFileURL(fixture)))
    #expect(Set(stats.categories.keys) == ["derived-data", "gradle"])

    // …and no second write follows.
    let mtime = try FileManager.default
        .attributesOfItem(atPath: statsFileURL(fixture).path(percentEncoded: false))[.modificationDate] as? Date
    try await Task.sleep(for: .milliseconds(400))
    let mtimeAfter = try FileManager.default
        .attributesOfItem(atPath: statsFileURL(fixture).path(percentEncoded: false))[.modificationDate] as? Date
    #expect(mtime == mtimeAfter)
}

@Test func flushForcesPendingWriteImmediately() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .seconds(60))
    await store.update(makeSnapshot("swiftpm-cache", bytes: 4096))
    #expect(!statsFileExists(fixture))
    await store.flush()
    #expect(statsFileExists(fixture))

    let reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    #expect(reloaded.map(\.categoryID.rawValue) == ["swiftpm-cache"])
}

@Test func snapshotWithoutUpdatedAtIsIgnored() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    await store.update(makeSnapshot("derived-data", bytes: 8192, updatedAt: nil))
    await store.flush()
    #expect(await store.load().isEmpty)
}

// MARK: - Adversarial-verifier pins (stale pre-clean stats)

@Test func noteCleanedDropsEntireItemsAndZeroesContentsOnlyRoots() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let entire = CacheItem(
        categoryID: CategoryID("derived-data"),
        url: URL(filePath: "/tmp/fixture/DerivedData/Foo-abc"),
        label: "Foo-abc")
    let contentsOnly = CacheItem(
        categoryID: CategoryID("derived-data"),
        url: URL(filePath: "/tmp/fixture/DerivedData/ModuleCache.noindex"),
        label: "ModuleCache.noindex",
        deletionMode: .contentsOnly)
    let snapshot = CategorySnapshot(
        categoryID: CategoryID("derived-data"),
        items: [
            MeasuredItem(item: entire, size: ItemSize(allocatedBytes: 8192, fileCount: 2)),
            MeasuredItem(item: contentsOnly, size: ItemSize(allocatedBytes: 4096, fileCount: 1)),
        ],
        updatedAt: Date())

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    await store.update(snapshot)
    // Deleted paths as SafeDeleter reports them: the entireItem itself
    // (with a trailing slash, as resolved directory URLs may carry) and a
    // CHILD of the contentsOnly root.
    await store.noteCleaned(
        category: CategoryID("derived-data"),
        deletedPaths: [
            "/tmp/fixture/DerivedData/Foo-abc/",
            "/tmp/fixture/DerivedData/ModuleCache.noindex/entry.dat",
        ])
    await store.flush()

    let reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    let category = try #require(reloaded.first { $0.categoryID.rawValue == "derived-data" })
    // The quit-right-after-clean scenario must show post-clean truth.
    #expect(category.totalBytes == 0)
    #expect(category.items.count == 1)
    #expect(category.items.first?.item.deletionMode == .contentsOnly)
}

@Test func invalidateDropsTheCategoryRecord() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let store = StatsStore(fileURL: statsFileURL(fixture), debounceInterval: .milliseconds(10))
    await store.update(makeSnapshot("gradle", bytes: 4096))
    await store.invalidate(category: CategoryID("gradle"))
    await store.flush()
    #expect(await store.load().isEmpty)
}

@Test func staleUpdateTokenCannotInvalidateNewerCleanOrScanTruth() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let category = CategoryID("derived-data")
    let store = StatsStore(
        fileURL: statsFileURL(fixture),
        debounceInterval: .milliseconds(10))
    let staleSnapshot = makeSnapshot("derived-data", bytes: 8_192)
    let staleToken = try #require(await store.update(staleSnapshot))

    let deletedPath = try #require(staleSnapshot.items.first)
        .item.url.path(percentEncoded: false)
    await store.noteCleaned(category: category, deletedPaths: [deletedPath])
    #expect(!(await store.invalidate(category: category, ifCurrent: staleToken)))
    await store.flush()

    var reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    var retained = try #require(reloaded.first { $0.categoryID == category })
    #expect(retained.items.isEmpty)
    #expect(retained.totalBytes == 0)

    let newerSnapshot = makeSnapshot(
        "derived-data",
        bytes: 16_384,
        updatedAt: Date(timeIntervalSinceNow: 1))
    _ = await store.update(newerSnapshot)
    #expect(!(await store.invalidate(category: category, ifCurrent: staleToken)))
    await store.flush()

    reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    retained = try #require(reloaded.first { $0.categoryID == category })
    #expect(retained.totalBytes == 16_384)

    let currentCategory = CategoryID("gradle")
    let currentToken = try #require(await store.update(
        makeSnapshot("gradle", bytes: 4_096)))
    #expect(await store.invalidate(
        category: currentCategory,
        ifCurrent: currentToken))
    await store.flush()
    reloaded = await StatsStore(fileURL: statsFileURL(fixture)).load()
    #expect(!reloaded.contains { $0.categoryID == currentCategory })
}
