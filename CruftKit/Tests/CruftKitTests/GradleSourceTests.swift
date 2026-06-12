import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct GradleSourceTests {
    @Test func discoversPlantedRootsAsContentsOnly() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let planted = try fixture.plantGradleFixture()
        let context = ScanContext(home: fixture.root)

        let items = try await GradleSource().discover(context: context)

        #expect(items.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: items.map {
            ($0.url.cruftCanonical.path(percentEncoded: false), $0)
        })
        let caches = byPath[planted.caches.cruftCanonical.path(percentEncoded: false)]
        let daemon = byPath[planted.daemon.cruftCanonical.path(percentEncoded: false)]
        #expect(caches?.label == "Gradle caches")
        #expect(daemon?.label == "Gradle daemon logs")
        for item in items {
            #expect(item.categoryID == GradleSource.id)
            // Depth edge: ~/.gradle/caches and ~/.gradle/daemon are only 2
            // path components below home — under SafeDeleter's 3-component
            // depth floor, so the roots themselves can never be deleted.
            // .contentsOnly is what makes their CHILDREN (3 components deep)
            // the deletion targets; .entireItem here would make the category
            // permanently uncleanable.
            #expect(item.deletionMode == .contentsOnly)
        }
    }

    @Test func missingRootsYieldEmptyWithoutThrowing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        let items = try await GradleSource().discover(context: context)
        #expect(items.isEmpty)
    }

    @Test func discoversOnlyTheRootThatExists() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDir(".gradle/daemon")
        let context = ScanContext(home: fixture.root)

        let items = try await GradleSource().discover(context: context)
        #expect(items.count == 1)
        #expect(items.first?.label == "Gradle daemon logs")
        #expect(items.first?.deletionMode == .contentsOnly)
    }

    @Test func decoysAreNotDiscovered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantGradleFixture(includeDecoys: true)
        let context = ScanContext(home: fixture.root)

        let items = try await GradleSource().discover(context: context)
        let paths = Set(items.map { $0.url.cruftCanonical.path(percentEncoded: false) })

        // Real roots present…
        #expect(paths.contains(fixture.url(".gradle/caches").cruftCanonical.path(percentEncoded: false)))
        #expect(paths.contains(fixture.url(".gradle/daemon").cruftCanonical.path(percentEncoded: false)))
        // …decoys absent: wrapper dists are NOT in v1, and gradle.properties
        // is user configuration (a file), not a cache.
        #expect(fixture.exists(".gradle/wrapper"))
        #expect(fixture.exists(".gradle/gradle.properties"))
        #expect(!paths.contains(fixture.url(".gradle/wrapper").cruftCanonical.path(percentEncoded: false)))
        #expect(!paths.contains(fixture.url(".gradle/gradle.properties").cruftCanonical.path(percentEncoded: false)))
        #expect(items.count == 2)
    }

    @Test func allowedDeletionRootsAreExactlyCachesAndDaemon() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        let roots = GradleSource().allowedDeletionRoots(context: context)
            .map { $0.cruftCanonical.path(percentEncoded: false) }
        let expected = [
            fixture.url(".gradle/caches").cruftCanonical.path(percentEncoded: false),
            fixture.url(".gradle/daemon").cruftCanonical.path(percentEncoded: false),
        ]
        #expect(roots == expected)
    }

    @Test func cleanRoutesItemsThroughTheDeleterWithAllowedRoots() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantGradleFixture()
        let context = ScanContext(home: fixture.root)
        let source = GradleSource()
        let deleter = RecordingDeleter()

        let items = try await source.discover(context: context)
        for item in items {
            try await source.clean(item: item, context: context, using: deleter)
        }

        let requests = await deleter.requests
        #expect(requests.count == items.count)
        for request in requests {
            #expect(request.allowedRoots == source.allowedDeletionRoots(context: context))
        }
        // RecordingDeleter never touches the disk — fixtures must survive.
        #expect(fixture.exists(".gradle/caches/modules-2/files-2.1/com.example/lib/1.0/lib-1.0.jar"))
        #expect(fixture.exists(".gradle/daemon/8.7/daemon-12345.out.log"))
    }
}
