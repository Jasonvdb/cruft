import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct SwiftPMCacheSourceTests {
    @Test func discoversPlantedRootAsContentsOnly() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let planted = try fixture.plantSwiftPMCacheFixture()
        let context = ScanContext(home: fixture.root)

        let items = try await SwiftPMCacheSource().discover(context: context)

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.categoryID == SwiftPMCacheSource.id)
        #expect(item.url.cruftCanonical.path(percentEncoded: false)
            == planted.cruftCanonical.path(percentEncoded: false))
        #expect(item.label == "SwiftPM cache")
        // The org.swift.swiftpm directory itself survives; only its children
        // (repositories/, manifests/, …) are deleted.
        #expect(item.deletionMode == .contentsOnly)
    }

    @Test func missingRootYieldsEmptyWithoutThrowing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        let items = try await SwiftPMCacheSource().discover(context: context)
        #expect(items.isEmpty)
    }

    @Test func siblingCacheDecoyIsNotDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantSwiftPMCacheFixture(includeDecoys: true)
        let context = ScanContext(home: fixture.root)

        let items = try await SwiftPMCacheSource().discover(context: context)
        let paths = Set(items.map { $0.url.cruftCanonical.path(percentEncoded: false) })

        // Real root present, foreign sibling cache absent.
        #expect(paths.contains(
            fixture.url("Library/Caches/org.swift.swiftpm").cruftCanonical.path(percentEncoded: false)))
        #expect(fixture.exists("Library/Caches/com.apple.somethingelse"))
        #expect(!paths.contains(
            fixture.url("Library/Caches/com.apple.somethingelse").cruftCanonical.path(percentEncoded: false)))
        #expect(items.count == 1)
    }

    @Test func allowedDeletionRootsAreExactlyTheSwiftPMCacheDir() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        let roots = SwiftPMCacheSource().allowedDeletionRoots(context: context)
            .map { $0.cruftCanonical.path(percentEncoded: false) }
        let expected = [
            fixture.url("Library/Caches/org.swift.swiftpm").cruftCanonical.path(percentEncoded: false),
        ]
        #expect(roots == expected)
    }

    @Test func cleanRoutesItemThroughTheDeleterWithAllowedRoots() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantSwiftPMCacheFixture()
        let context = ScanContext(home: fixture.root)
        let source = SwiftPMCacheSource()
        let deleter = RecordingDeleter()

        let items = try await source.discover(context: context)
        let item = try #require(items.first)
        try await source.clean(item: item, context: context, using: deleter)

        let requests = await deleter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.item == item)
        #expect(requests.first?.allowedRoots == source.allowedDeletionRoots(context: context))
        // RecordingDeleter never touches the disk — fixtures must survive.
        #expect(fixture.exists("Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/manifest.db"))
    }
}
