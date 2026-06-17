import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct CargoSourceTests {
    private let source = CargoSource()

    private func paths(_ items: [CacheItem]) -> Set<String> {
        Set(items.map { $0.url.path(percentEncoded: false) })
    }

    private func path(_ fixture: FixtureHome, _ projectRelative: String) -> String {
        fixture.projectURL(projectRelative).path(percentEncoded: false)
    }

    @Test func standaloneCrateTargetDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("pkresolver")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "pkresolver/target")])
        let item = try #require(items.first)
        #expect(item.categoryID == CargoSource.id)
        #expect(item.label == "pkresolver/target")
        #expect(item.deletionMode == .entireItem)
    }

    @Test func targetWithoutCargoTomlIsNotDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // A bare target/ (Maven, ad-hoc scripts) with no Cargo.toml sibling.
        try fixture.plantBuildDir("MavenLike/target")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
    }

    @Test func cargoTomlWithoutTargetReportsNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("freshlyCloned", withTarget: false)

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
    }

    @Test func workspaceRootTargetFoundMemberCratesIgnored() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // Cargo writes target/ only at the workspace root; member crates have
        // their own Cargo.toml but no target/.
        try fixture.plantCargoPackage("ws")
        try fixture.plantCargoPackage("ws/crates/core", withTarget: false)
        try fixture.plantCargoPackage("ws/crates/cli", withTarget: false)

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "ws/target")])
    }

    @Test func cargoTomlDirectoryDoesNotMarkProject() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // Marker KIND matters: a *directory* named Cargo.toml must not expose
        // a sibling target/ that is not Cargo output.
        try fixture.plantDir("\(fixture.projectsRootPath)/Tricky/Cargo.toml")
        try fixture.plantFile("\(fixture.projectsRootPath)/Tricky/target/victim.bin")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
    }

    @Test func hiddenAndNodeModulesNeverEntered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("Real")
        // Decoys: fully-equipped crates that must never be reached.
        try fixture.plantCargoPackage(".cache/Hidden")
        try fixture.plantCargoPackage("web/node_modules/somecrate")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Real/target")])
    }

    @Test func symlinkedTargetNotFollowed() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("Genuine")
        // A real crate outside the projects root, plus a symlinked target/
        // inside a real crate — neither is an item.
        try fixture.plantFile("Elsewhere/RealCrate/Cargo.toml")
        try fixture.plantFile("Elsewhere/RealCrate/target/payload.o")
        try fixture.plantFile("\(fixture.projectsRootPath)/Linker/Cargo.toml")
        try fixture.plantSymlink(
            at: "\(fixture.projectsRootPath)/Linker/target",
            to: fixture.url("Elsewhere/RealCrate/target").path(percentEncoded: false))

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Genuine/target")])
    }

    @Test func nestedCrateInsideReportedTargetNotDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("Outer")
        // A crate vendored inside the reported target/ stays invisible — the
        // walk never descends into a target/ it reported.
        try fixture.plantCargoPackage("Outer/target/vendored")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Outer/target")])
    }

    @Test func depthLimitIsFourLevels() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("a/b/c/Crate4")          // depth 4: in range
        try fixture.plantCargoPackage("a/b/c/d/Crate5")        // depth 5: beyond

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "a/b/c/Crate4/target")])
    }

    @Test func missingProjectsRootReturnsEmpty() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let items = try await source.discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func allowedDeletionRootsIsProjectsRoot() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)
        #expect(source.allowedDeletionRoots(context: context) == [context.projectsRoot])
    }

    @Test func cleanRoutesThroughDeleterWithProjectsRootAllowed() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantCargoPackage("pkresolver")
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)

        let deleter = RecordingDeleter()
        let deleted = try await source.clean(item: item, context: context, using: deleter)

        #expect(deleted == [item.url])
        let requests = await deleter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.allowedRoots == [context.projectsRoot])
        // RecordingDeleter records without deleting.
        #expect(fixture.exists("\(fixture.projectsRootPath)/pkresolver/target/payload.o"))
    }
}
