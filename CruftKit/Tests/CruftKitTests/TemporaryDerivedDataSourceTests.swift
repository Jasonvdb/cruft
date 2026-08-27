import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite("TemporaryDerivedDataSource")
struct TemporaryDerivedDataSourceTests {
    @Test func discoversOnlyDirectRealXcodeShapedDirectories() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)
        let valid = try fixture.plantTemporaryDerivedDataFixture()
        try fixture.plantDir("private-tmp/Not-Build-Data/Build")
        try fixture.plantDir("private-tmp/Fake-DerivedData/Logs")
        let outside = try fixture.plantDir("outside/Linked-DerivedData/Build")
        try fixture.plantDir("outside/Linked-DerivedData/Logs")
        try fixture.plantSymlink(
            at: "private-tmp/Linked-DerivedData",
            to: outside.deletingLastPathComponent().path(percentEncoded: false))

        let items = try await TemporaryDerivedDataSource().discover(context: context)

        #expect(items.count == 1)
        #expect(items.first?.url.path(percentEncoded: false)
            == valid.cruftCanonical.path(percentEncoded: false))
        #expect(items.first?.deletionMode == .temporaryDerivedData)
    }

    @Test func ageAndCompleteMeasurementAreRequiredForPlanning() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        _ = try fixture.plantTemporaryDerivedDataFixture()
        let source = TemporaryDerivedDataSource()
        let item = try #require(try await source.discover(
            context: ScanContext(home: fixture.root)).first)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = ItemSize(
            allocatedBytes: 4096,
            fileCount: 1,
            newestModificationDate: now.addingTimeInterval(-4 * 24 * 60 * 60))
        let recent = ItemSize(
            allocatedBytes: 4096,
            fileCount: 1,
            newestModificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let incomplete = ItemSize(
            allocatedBytes: 4096,
            fileCount: 1,
            erroredEntries: 1,
            newestModificationDate: now.addingTimeInterval(-4 * 24 * 60 * 60))

        #expect(GuardedCleanupPolicy.hasCompleteOldMeasurement(old, now: now))
        #expect(!GuardedCleanupPolicy.hasCompleteOldMeasurement(recent, now: now))
        #expect(!GuardedCleanupPolicy.hasCompleteOldMeasurement(incomplete, now: now))
        #expect(!GuardedCleanupPolicy.hasCompleteOldMeasurement(nil, now: now))
        #expect(source.canClean(item: item))
    }

    @Test func explicitItemRoutesThroughDeletionSeamAndBulkPathsStayDisabled() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        _ = try fixture.plantTemporaryDerivedDataFixture()
        let source = TemporaryDerivedDataSource()
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)
        let deleter = RecordingDeleter()

        let deleted = try await source.clean(item: item, context: context, using: deleter)

        #expect(deleted == [item.url])
        #expect(await deleter.requests.count == 1)
        #expect(source.supportsCleaning)
        #expect(!source.allowsWholeCategoryCleaning)
        #expect(!source.includedInCleanAllByDefault)
        #expect(!source.isDestructive)
    }
}
