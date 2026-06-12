import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct XcodeBuildMCPSourceTests {
    private let source = XcodeBuildMCPSource()

    /// Canonical path string without a trailing slash — directory URLs from
    /// `contentsOfDirectory` carry a trailing-slash hint that plain
    /// `appending(path:)` URLs lack, so string comparisons normalize it.
    private func canonicalPath(_ url: URL) -> String {
        var path = url.cruftCanonical.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    @Test func discoversDirectChildDirectoriesAsEntireItemsSortedByLabel() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantXcodeBuildMCPWorkspace("MockupCreator-6dbf557ddd52")
        try fixture.plantXcodeBuildMCPWorkspace("ChessClock-f6d4b377332a")
        try fixture.plantXcodeBuildMCPWorkspacesRootFile("ChessClock-f6d4b377332a.lock")
        let decoys = try fixture.plantXcodeBuildMCPDecoys()
        // Xcode's own DerivedData is a different category's territory — a
        // project planted there must never surface as an item here.
        try fixture.plantDerivedDataProject("NotATarget-abcdefghijkl")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.map(\.label) == [
            "ChessClock-f6d4b377332a", "MockupCreator-6dbf557ddd52",
        ])
        #expect(items.allSatisfy { $0.deletionMode == .entireItem })
        #expect(items.allSatisfy { $0.categoryID == XcodeBuildMCPSource.id })

        // Every item sits directly under the workspaces root…
        let rootPath = canonicalPath(fixture.url(FixtureHome.xcodeBuildMCPWorkspacesPath))
        for item in items {
            #expect(canonicalPath(item.url).hasPrefix(rootPath + "/"))
        }
        // …and no decoy sibling was ever discovered (they do exist on disk).
        let nonTargets = decoys
            + ["\(FixtureHome.derivedDataPath)/NotATarget-abcdefghijkl"]
        for nonTarget in nonTargets {
            #expect(fixture.exists(nonTarget))
            let nonTargetPath = canonicalPath(fixture.url(nonTarget))
            #expect(!items.contains { canonicalPath($0.url) == nonTargetPath })
        }
    }

    @Test func nonDirectoryChildrenAreNotItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantXcodeBuildMCPWorkspacesRootFile("DemoApp-abc123.lock")
        try fixture.plantXcodeBuildMCPWorkspacesRootFile("registry.json")

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func symlinkedChildrenAreNotItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantXcodeBuildMCPWorkspacesRoot()
        let decoys = try fixture.plantXcodeBuildMCPDecoys()
        // A symlink at the root pointing outside workspaces must never
        // become an item — deleting through it would escape the root.
        try fixture.plantSymlink(
            at: "\(FixtureHome.xcodeBuildMCPWorkspacesPath)/Escape-abc123",
            to: fixture.url(decoys[1]).path(percentEncoded: false))

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func decoysAloneDiscoverNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let decoys = try fixture.plantXcodeBuildMCPDecoys()
        try fixture.plantDerivedDataProject("NotATarget-abcdefghijkl")

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
        try fixture.plantXcodeBuildMCPWorkspacesRoot()

        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func allowedDeletionRootsIsExactlyTheWorkspacesDirectory() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        let roots = source.allowedDeletionRoots(context: ScanContext(home: fixture.root))
        #expect(roots.map(\.cruftCanonical) ==
            [fixture.url(FixtureHome.xcodeBuildMCPWorkspacesPath).cruftCanonical])
    }

    @Test func cleanRoutesThroughTheDeleterSeamWithTheWorkspacesRoot() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantXcodeBuildMCPWorkspace("MockupCreator-6dbf557ddd52")
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
            [fixture.url(FixtureHome.xcodeBuildMCPWorkspacesPath).cruftCanonical])
        // RecordingDeleter deletes nothing — the fixture must survive.
        #expect(fixture.exists(
            "\(FixtureHome.xcodeBuildMCPWorkspacesPath)/MockupCreator-6dbf557ddd52"))
    }

    @Test func categoryMetadataMatchesContract() {
        #expect(XcodeBuildMCPSource.id == CategoryID("xcodebuild-mcp"))
        #expect(source.displayName == "XcodeBuildMCP Workspaces")
        #expect(source.includedInCleanAllByDefault)
        #expect(!source.isDestructive)
    }

    // Adversarial-verifier pin: item URLs are rebuilt on the parent so ids
    // never embed contentsOfDirectory's trailing slash (StatsStore and CLI
    // --exclude match on ids; "/path/" vs "/path" must not double-count).
    @Test func itemPathsCarryNoTrailingSlash() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantXcodeBuildMCPWorkspace("Demo-abc123")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        for item in items {
            #expect(!item.url.path(percentEncoded: false).hasSuffix("/"))
            #expect(!item.id.hasSuffix("/"))
        }
    }
}
