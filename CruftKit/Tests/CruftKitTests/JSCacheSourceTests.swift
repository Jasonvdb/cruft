import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private func canonicalPath(_ url: URL) -> String {
    url.cruftCanonical.path(percentEncoded: false)
}

@Test func jsCacheDiscoversAllFourPlantedRootsAsContentsOnly() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let cacache = try fixture.plantNpmCacacheFixture()
    let yarn = try fixture.plantYarnCacheFixture()
    let pnpmCache = try fixture.plantPnpmCacheFixture()
    let pnpmStore = try fixture.plantPnpmStoreFixture()
    try fixture.plantNpmDecoys()
    try fixture.plantPnpmGlobalDecoy()

    let items = try await JSCacheSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.count == 4)
    #expect(items.allSatisfy { $0.categoryID == JSCacheSource.id })
    #expect(items.allSatisfy { $0.deletionMode == .contentsOnly })
    let labelsByPath = Dictionary(uniqueKeysWithValues: items.map { (canonicalPath($0.url), $0.label) })
    #expect(labelsByPath[canonicalPath(cacache)] == "npm cache")
    #expect(labelsByPath[canonicalPath(yarn)] == "Yarn cache")
    #expect(labelsByPath[canonicalPath(pnpmCache)] == "pnpm cache")
    #expect(labelsByPath[canonicalPath(pnpmStore)] == "pnpm store")
}

@Test func jsCacheDiscoversOnlyTheRootsThatExist() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let yarn = try fixture.plantYarnCacheFixture()
    try fixture.plantNpmDecoys()
    try fixture.plantPnpmGlobalDecoy()

    let items = try await JSCacheSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.count == 1)
    #expect(items.first.map { canonicalPath($0.url) } == canonicalPath(yarn))
    #expect(items.first?.label == "Yarn cache")
}

@Test func jsCacheReturnsNothingWhenRootsAreMissing() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    // Decoys only — `.npm/_logs`, `.npmrc` and `Library/pnpm/global` exist
    // but no cache root does; discovery must come back empty without
    // throwing.
    try fixture.plantNpmDecoys()
    try fixture.plantPnpmGlobalDecoy()

    let items = try await JSCacheSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.isEmpty)
}

/// Negative test: only `_cacache` inside `~/.npm` and only `store` inside
/// `~/Library/pnpm` are cache — `.npm/_logs`, the `.npmrc` sibling file and
/// `Library/pnpm/global` (installed packages) must never be discovered nor
/// sit inside any allowed deletion root.
@Test func jsCacheNeverDiscoversOrCoversNpmAndPnpmDecoys() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantNpmCacacheFixture()
    try fixture.plantYarnCacheFixture()
    try fixture.plantPnpmCacheFixture()
    try fixture.plantPnpmStoreFixture()
    var decoys = try fixture.plantNpmDecoys()
    decoys.append(try fixture.plantPnpmGlobalDecoy())

    let source = JSCacheSource()
    let context = ScanContext(home: fixture.root)
    let items = try await source.discover(context: context)
    let roots = source.allowedDeletionRoots(context: context)

    for decoy in decoys {
        let decoyPath = canonicalPath(decoy)
        #expect(!items.contains { canonicalPath($0.url) == decoyPath })
        #expect(!items.contains { decoyPath.hasPrefix(canonicalPath($0.url) + "/") })
        for root in roots {
            let rootPath = canonicalPath(root)
            #expect(decoyPath != rootPath)
            #expect(!decoyPath.hasPrefix(rootPath + "/"))
        }
    }
}

@Test func jsCacheAllowedRootsAreExactlyTheFourCacheRoots() throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let roots = JSCacheSource().allowedDeletionRoots(context: ScanContext(home: fixture.root))

    #expect(roots.count == 4)
    #expect(Set(roots.map(canonicalPath)) == Set([
        canonicalPath(fixture.url(".npm/_cacache")),
        canonicalPath(fixture.url("Library/Caches/Yarn")),
        canonicalPath(fixture.url("Library/Caches/pnpm")),
        canonicalPath(fixture.url("Library/pnpm/store")),
    ]))
}

/// Depth edge: `~/.npm/_cacache` lives only 2 path components below home —
/// under SafeDeleter's depth floor (rule 5 refuses anything fewer than 3
/// below home), so the root could never legally be removed as
/// `.entireItem`. Its direct children sit exactly 3 below home and clear
/// the floor, which is why `.contentsOnly` is load-bearing here: SafeDeleter
/// empties the root child-by-child (each individually re-validated) and the
/// `_cacache` directory itself always survives.
@Test func jsCacheNpmCacacheIsContentsOnlyBecauseOfTheDepthFloor() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let cacache = try fixture.plantNpmCacacheFixture()
    try fixture.plantNpmDecoys()

    let items = try await JSCacheSource().discover(context: ScanContext(home: fixture.root))
    let item = try #require(items.first { canonicalPath($0.url) == canonicalPath(cacache) })

    #expect(item.deletionMode == .contentsOnly)
    // The discovered URL is the _cacache root itself, never `.npm`.
    #expect(item.url.lastPathComponent == "_cacache")
}

@Test func jsCacheCleanRoutesThroughTheDeleterSeam() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantNpmCacacheFixture()
    try fixture.plantNpmDecoys()

    let source = JSCacheSource()
    let context = ScanContext(home: fixture.root)
    let item = try #require(try await source.discover(context: context).first)
    let deleter = RecordingDeleter()

    let deleted = try await source.clean(item: item, context: context, using: deleter)

    #expect(deleted == [item.url])
    let requests = await deleter.requests
    #expect(requests.count == 1)
    #expect(requests.first?.item == item)
    #expect(requests.first.map { $0.allowedRoots.map(canonicalPath) }
        == source.allowedDeletionRoots(context: context).map(canonicalPath))
    // RecordingDeleter deletes nothing — the planted payload survives.
    #expect(fixture.exists(".npm/_cacache/content-v2/sha512/payload.bin"))
}
