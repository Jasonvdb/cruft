import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

@Suite struct ArchivesSourceTests {
    /// Trailing-slash-insensitive canonical path, so directory URLs from
    /// `contentsOfDirectory` compare equal to fixture-built URLs.
    private func path(_ url: URL) -> String {
        var p = url.cruftCanonical.path(percentEncoded: false)
        if p.hasSuffix("/") { p.removeLast() }
        return p
    }

    @Test func discoversDateDirAndRootLevelArchivesAndIgnoresDecoys() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        let dated = try fixture.plantXcodeArchiveFixture(
            name: "MyApp 2026-06-01, 09.41", dateDir: "2026-06-01")
        let dated2 = try fixture.plantXcodeArchiveFixture(
            name: "Widget 2026-06-02, 18.05", dateDir: "2026-06-02")
        let loose = try fixture.plantXcodeArchiveFixture(name: "Loose", dateDir: nil)

        // Decoys — none of these may become items.
        try fixture.plantFile("Library/Developer/Xcode/Archives/README.md")
        try fixture.plantFile("Library/Developer/Xcode/Archives/Fake.xcarchive")
        try fixture.plantFile("Library/Developer/Xcode/Archives/2026-06-01/notes.txt")
        try fixture.plantDir("Library/Developer/Xcode/Archives/2026-06-01/NotAnArchive")
        try fixture.plantDir("Library/Developer/Xcode/Archives/Stash/nested/Deep.xcarchive")
        try fixture.plantDir("Library/Developer/Xcode/Archives/Loose.xcarchive/Inner.xcarchive")
        try fixture.plantDir("Outside.xcarchive")
        try fixture.plantSymlink(
            at: "Library/Developer/Xcode/Archives/Linked.xcarchive", to: fixture.url("Outside.xcarchive").path(percentEncoded: false))

        let items = try await ArchivesSource().discover(context: ScanContext(home: fixture.root))

        #expect(Set(items.map { path($0.url) }) == Set([dated, dated2, loose].map { path($0) }))
        #expect(items.allSatisfy { $0.deletionMode == .entireItem })
        #expect(items.allSatisfy { $0.categoryID == ArchivesSource.id })
        #expect(Set(items.map(\.label)) == [
            "MyApp 2026-06-01, 09.41", "Widget 2026-06-02, 18.05", "Loose",
        ])
    }

    @Test func emptyDateDirsYieldNothing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        try fixture.plantEmptyArchiveDateDir("2026-05-01")
        try fixture.plantEmptyArchiveDateDir("2026-05-02")
        try fixture.plantFile("Library/Developer/Xcode/Archives/.DS_Store")

        let items = try await ArchivesSource().discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func missingRootYieldsEmptyWithoutThrowing() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }

        // An archive bundle OUTSIDE the Archives root must never be found.
        try fixture.plantDir("Library/Developer/Xcode/DerivedData/Stray.xcarchive")

        let items = try await ArchivesSource().discover(context: ScanContext(home: fixture.root))
        #expect(items.isEmpty)
    }

    @Test func safetyFlagsKeepArchivesOutOfCleanAll() {
        let source = ArchivesSource()
        // Archives hold release dSYMs; this category must never slip into
        // Clean All by default and must surface the destructive warning.
        #expect(source.includedInCleanAllByDefault == false)
        #expect(source.isDestructive == true)
        #expect(ArchivesSource.id.rawValue == "xcode-archives")
    }

    @Test func allowedDeletionRootsIsExactlyTheArchivesRoot() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        let roots = ArchivesSource().allowedDeletionRoots(context: context)
        #expect(roots.map { path($0) } == [path(fixture.url("Library/Developer/Xcode/Archives"))])
    }

    @Test func cleanRoutesThroughDeleterSeam() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let context = ScanContext(home: fixture.root)

        try fixture.plantXcodeArchiveFixture(name: "MyApp 2026-06-01, 09.41", dateDir: "2026-06-01")
        try fixture.plantXcodeArchiveFixture(name: "Decoy", dateDir: "2026-06-03")

        let source = ArchivesSource()
        let items = try await source.discover(context: context)
        let target = try #require(items.first { $0.label.hasPrefix("MyApp") })

        let deleter = RecordingDeleter()
        let deleted = try await source.clean(item: target, context: context, using: deleter)

        #expect(deleted == [target.url])
        let requests = await deleter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.allowedRoots.map { path($0) }
            == [path(fixture.url("Library/Developer/Xcode/Archives"))])
        // RecordingDeleter deletes nothing — both archives must survive.
        #expect(fixture.exists("Library/Developer/Xcode/Archives/2026-06-01/MyApp 2026-06-01, 09.41.xcarchive/Info.plist"))
        #expect(fixture.exists("Library/Developer/Xcode/Archives/2026-06-03/Decoy.xcarchive/Info.plist"))
    }
}
