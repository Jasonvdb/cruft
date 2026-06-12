import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct DerivedDataSourceTests {
    private let source = DerivedDataSource()

    /// Canonical path string without a trailing slash — directory URLs from
    /// `contentsOfDirectory` carry a trailing-slash hint that plain
    /// `appending(path:)` URLs lack, so string comparisons normalize it.
    private func canonicalPath(_ url: URL) -> String {
        var path = url.cruftCanonical.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    @Test func discoversDirectChildDirectoriesAsEntireItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataProject("MockupCreator-abcdefghijkl")
        try fixture.plantDerivedDataProject("ChessClock-aaaabbbbcccc")
        try fixture.plantDerivedDataSharedCache("ModuleCache.noindex")
        try fixture.plantDerivedDataSharedCache("SymbolCache.noindex")
        try fixture.plantDerivedDataRootFile("MockupCreator-abcdefghijkl.lock")
        let decoys = try fixture.plantDerivedDataDecoys()

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(Set(items.map(\.label)) == [
            "ChessClock-aaaabbbbcccc", "MockupCreator-abcdefghijkl",
            "ModuleCache.noindex", "SymbolCache.noindex",
        ])
        #expect(items.allSatisfy { $0.deletionMode == .entireItem })
        #expect(items.allSatisfy { $0.categoryID == DerivedDataSource.id })

        // Every item sits directly under the DerivedData root…
        let rootPath = canonicalPath(fixture.url(FixtureHome.derivedDataPath))
        for item in items {
            #expect(canonicalPath(item.url).hasPrefix(rootPath + "/"))
        }
        // …and no decoy sibling was ever discovered (they do exist on disk).
        for decoy in decoys {
            #expect(fixture.exists(decoy))
            let decoyPath = canonicalPath(fixture.url(decoy))
            #expect(!items.contains { canonicalPath($0.url) == decoyPath })
        }
    }

    @Test func nonDirectoryChildrenAreNotItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataRootFile("ModuleCache.noindex.lock")
        try fixture.plantDerivedDataRootFile("info.plist")

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func symlinkedChildrenAreNotItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataRoot()
        let decoys = try fixture.plantDerivedDataDecoys()
        // A symlink at the root pointing outside DerivedData must never
        // become an item — deleting through it would escape the root.
        try fixture.plantSymlink(
            at: "\(FixtureHome.derivedDataPath)/Escape-abcdef",
            to: fixture.url(decoys[1]).path(percentEncoded: false))

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func decoysAloneDiscoverNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let decoys = try fixture.plantDerivedDataDecoys()

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
        for decoy in decoys { #expect(fixture.exists(decoy)) }
    }

    @Test func missingRootDiscoversNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func emptyRootDiscoversNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataRoot()

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func allowedDeletionRootsIsExactlyTheDerivedDataDirectory() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        let roots = source.allowedDeletionRoots(context: ScanContext(home: fixture.root))
        #expect(roots.map(\.cruftCanonical) ==
            [fixture.url(FixtureHome.derivedDataPath).cruftCanonical])
    }

    @Test func cleanRoutesThroughTheDeleterSeamWithTheDerivedDataRoot() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataProject("MockupCreator-abcdefghijkl")
        let context = ScanContext(home: fixture.root)

        let items = try await source.discover(context: context)
        let item = try #require(items.first)
        let deleter = RecordingDeleter()
        let deleted = try await source.clean(item: item, context: context, using: deleter)

        #expect(deleted == [item.url])
        let requests = await deleter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.item == item)
        #expect(requests.first?.allowedRoots.map(\.cruftCanonical) ==
            [fixture.url(FixtureHome.derivedDataPath).cruftCanonical])
        // RecordingDeleter deletes nothing — the fixture must survive.
        #expect(fixture.exists("\(FixtureHome.derivedDataPath)/MockupCreator-abcdefghijkl"))
    }

    @Test func categoryMetadataMatchesContract() {
        #expect(DerivedDataSource.id == CategoryID("derived-data"))
        #expect(source.displayName == "Xcode DerivedData")
        #expect(source.includedInCleanAllByDefault)
        #expect(!source.isDestructive)
    }

    // Adversarial-verifier pin: item URLs are rebuilt on the parent so ids
    // never embed contentsOfDirectory's trailing slash (StatsStore and CLI
    // --exclude match on ids; "/path/" vs "/path" must not double-count).
    @Test func itemPathsCarryNoTrailingSlash() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDerivedDataProject("Demo-abc")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        for item in items {
            #expect(!item.url.path(percentEncoded: false).hasSuffix("/"))
            #expect(!item.id.hasSuffix("/"))
        }
    }
}
