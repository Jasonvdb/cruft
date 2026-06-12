import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct InRepoBuildSourceTests {
    private let source = InRepoBuildSource()

    private func paths(_ items: [CacheItem]) -> Set<String> {
        Set(items.map { $0.url.path(percentEncoded: false) })
    }

    private func path(_ fixture: FixtureHome, _ projectRelative: String) -> String {
        fixture.projectURL(projectRelative).path(percentEncoded: false)
    }

    @Test func xcodeProjectBuildDirDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "ChessClock", markers: ["ChessClock.xcodeproj"], buildDirs: ["build"])
        // Decoy: a build/ with no project-marker sibling is just a directory.
        try fixture.plantBuildDir("RandomStuff/build")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "ChessClock/build")])
        let item = try #require(items.first)
        #expect(item.categoryID == InRepoBuildSource.id)
        #expect(item.label == "ChessClock/build")
        #expect(item.deletionMode == .entireItem)
    }

    @Test func swiftPMDotBuildDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "CruftKitFork", markers: ["Package.swift"], buildDirs: [".build"])
        // Decoy: hidden directories are never entered, even with markers.
        try fixture.plantInRepoProject(
            ".foo", markers: ["Package.swift"], buildDirs: ["build"])

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "CruftKitFork/.build")])
        #expect(items.first?.label == "CruftKitFork/.build")
    }

    @Test func gradleAndroidNestedProjectsDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // android/ and android/app/ are BOTH projects; app/build is found
        // via app being a project one level deeper, never by descending
        // into a reported item.
        try fixture.plantInRepoProject(
            "LegalDraftAI/android", markers: ["build.gradle"], buildDirs: [".gradle"])
        try fixture.plantInRepoProject(
            "LegalDraftAI/android/app", markers: ["build.gradle"], buildDirs: ["build"])
        // Decoy: .git is hidden — never entered even when it contains a
        // marker and a build dir.
        try fixture.plantInRepoProject(
            "LegalDraftAI/android/.git", markers: ["build.gradle"], buildDirs: ["build"])

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [
            path(fixture, "LegalDraftAI/android/.gradle"),
            path(fixture, "LegalDraftAI/android/app/build"),
        ])
        #expect(Set(items.map(\.label)) == ["android/.gradle", "app/build"])
    }

    @Test func allFourItemsAcrossProjectKinds() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "ChessClock", markers: ["ChessClock.xcodeproj"], buildDirs: ["build"])
        try fixture.plantInRepoProject(
            "CruftKitFork", markers: ["Package.swift"], buildDirs: [".build"])
        try fixture.plantInRepoProject(
            "LegalDraftAI/android", markers: ["build.gradle"], buildDirs: [".gradle"])
        try fixture.plantInRepoProject(
            "LegalDraftAI/android/app", markers: ["build.gradle"], buildDirs: ["build"])
        // Decoys across the rule set.
        try fixture.plantBuildDir("Stray/build")
        try fixture.plantInRepoProject(
            "WebApp/node_modules/somepkg", markers: ["build.gradle"], buildDirs: ["build"])
        try fixture.plantFile("\(fixture.projectsRootPath)/WebApp/node_modules/somepkg/package.json")
        try fixture.plantInRepoProject(
            "ChessClock/.git", markers: ["Package.swift"], buildDirs: ["build"])

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.count == 4)
        #expect(paths(items) == [
            path(fixture, "ChessClock/build"),
            path(fixture, "CruftKitFork/.build"),
            path(fixture, "LegalDraftAI/android/.gradle"),
            path(fixture, "LegalDraftAI/android/app/build"),
        ])
    }

    @Test func nodeModulesNeverEntered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "WebApp", markers: ["settings.gradle"], buildDirs: ["build"])
        // Decoy: a fully marker-equipped package under node_modules.
        try fixture.plantInRepoProject(
            "WebApp/node_modules/somepkg", markers: ["build.gradle"], buildDirs: ["build"])
        try fixture.plantFile("\(fixture.projectsRootPath)/WebApp/node_modules/somepkg/package.json")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "WebApp/build")])
    }

    @Test func depthLimitIsFourLevels() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // Depth 4 below the projects root is the deepest project candidate…
        try fixture.plantInRepoProject(
            "a/b/c/Proj4", markers: ["Package.swift"], buildDirs: [".build"])
        // …depth 5 is beyond the walk.
        try fixture.plantInRepoProject(
            "a/b/c/d/Proj5", markers: ["Package.swift"], buildDirs: [".build", "build"])

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "a/b/c/Proj4/.build")])
    }

    @Test func symlinkedDirectoriesNotFollowed() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "Genuine", markers: ["Package.swift"], buildDirs: [".build"])
        // Decoy: a real marker directory outside the projects root, reached
        // only through a symlink planted inside it.
        try fixture.plantFile("Elsewhere/RealProj/Package.swift")
        try fixture.plantFile("Elsewhere/RealProj/build/payload.o")
        try fixture.plantSymlink(
            at: "\(fixture.projectsRootPath)/LinkedProj",
            to: fixture.url("Elsewhere/RealProj").path(percentEncoded: false))
        // Decoy: a symlinked build/ inside a real project is not an item.
        try fixture.plantInRepoProject("Linker", markers: ["Package.swift"])
        try fixture.plantSymlink(
            at: "\(fixture.projectsRootPath)/Linker/build",
            to: fixture.url("Elsewhere/RealProj/build").path(percentEncoded: false))

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Genuine/.build")])
    }

    @Test func reportedItemNotDescendedInto() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "Outer", markers: ["Outer.xcworkspace"], buildDirs: ["build"])
        // Decoy: a project nested inside the reported build/ stays invisible.
        try fixture.plantInRepoProject(
            "Outer/build/Sub", markers: ["Package.swift"], buildDirs: [".build"])

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Outer/build")])
    }

    @Test func bundleDirectoriesNotEntered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "Foo", markers: ["Foo.xcodeproj"], buildDirs: ["build"])
        // Decoy: a real .xcodeproj bundle directly contains
        // project.xcworkspace (a marker) — entering it would make the bundle
        // itself look like a project.
        try fixture.plantFile(
            "\(fixture.projectsRootPath)/Foo/Foo.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
        try fixture.plantBuildDir("Foo/Foo.xcodeproj/build")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(paths(items) == [path(fixture, "Foo/build")])
    }

    @Test func duplicateBuildNamesGetDistinctIDsAndLabels() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantInRepoProject(
            "ChessClock", markers: ["ChessClock.xcodeproj"], buildDirs: ["build"])
        try fixture.plantInRepoProject(
            "FaxApp", markers: ["FaxApp.xcodeproj"], buildDirs: ["build"])
        try fixture.plantBuildDir("NoMarker/build")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(Set(items.map(\.label)) == ["ChessClock/build", "FaxApp/build"])
    }

    @Test func missingProjectsRootReturnsEmpty() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // Nothing planted: home exists, Documents/Repositories does not.
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
        try fixture.plantInRepoProject(
            "ChessClock", markers: ["ChessClock.xcodeproj"], buildDirs: ["build"])
        try fixture.plantBuildDir("NoMarker/build")
        let context = ScanContext(home: fixture.root)
        let items = try await source.discover(context: context)
        let item = try #require(items.first)

        let deleter = RecordingDeleter()
        let deleted = try await source.clean(item: item, context: context, using: deleter)

        #expect(deleted == [item.url])
        let requests = await deleter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.allowedRoots == [context.projectsRoot])
        // RecordingDeleter records without deleting.
        #expect(fixture.exists("\(fixture.projectsRootPath)/ChessClock/build/payload.o"))
    }

    // Adversarial-verifier pin: marker KIND matters. A directory named
    // "build.gradle" or a stray file named "Foo.xcodeproj" must not mark
    // the parent as a project — otherwise an unrelated sibling "build/"
    // directory becomes a deletable item.
    @Test func wrongKindMarkersDoNotMakeAProject() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDir("\(fixture.projectsRootPath)/DirMarker/build.gradle")
        try fixture.plantFile("\(fixture.projectsRootPath)/DirMarker/build/victim.bin")
        try fixture.plantFile("\(fixture.projectsRootPath)/FileMarker/Foo.xcodeproj", bytes: 4096)
        try fixture.plantFile("\(fixture.projectsRootPath)/FileMarker/build/victim.bin")

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
    }
}
