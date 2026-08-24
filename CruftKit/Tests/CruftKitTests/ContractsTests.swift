import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private struct DefaultCleaningSource: CacheSource {
    static let id = CategoryID("default-cleaning")
    let displayName = "Default Cleaning"
    func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: "default-cleaning")]
    }
    func discover(context: ScanContext) async throws -> [CacheItem] { [] }
}

private struct ViewOnlyContractSource: CacheSource {
    static let id = CategoryID("view-only-contract")
    let displayName = "View Only"
    let supportsCleaning = false
    func allowedDeletionRoots(context: ScanContext) -> [URL] { [] }
    func discover(context: ScanContext) async throws -> [CacheItem] { [] }
}

@Test func scanContextCanonicalizesHome() {
    // /tmp and /private/tmp must converge to ONE canonical form (macOS
    // Foundation strips the /private prefix), or SafeDeleter's prefix
    // checks would refuse every fixture deletion.
    let viaTmp = ScanContext(home: URL(filePath: "/tmp"))
    let viaPrivate = ScanContext(home: URL(filePath: "/private/tmp"))
    #expect(viaTmp.home == viaPrivate.home)
    #expect(viaTmp.projectsRoot.path(percentEncoded: false)
        .hasPrefix(viaTmp.home.path(percentEncoded: false)))
}

@Test func fixtureHomeRootIsCanonicalAndPlantsWork() throws {
    let fixture = try FixtureHome(at: URL(filePath: "/tmp/cruft-p0-\(UUID().uuidString.prefix(8))"))
    defer { try? fixture.destroy() }

    // Root is already canonical (idempotent under cruftCanonical) and
    // recognized as a temp area by the destroy() guard.
    #expect(fixture.root == fixture.root.cruftCanonical)
    #expect(systemTempAreaPrefixes.contains(where: fixture.root.path(percentEncoded: false).hasPrefix))

    try fixture.plantFile("Library/Developer/Xcode/DerivedData/Demo-abc/file.bin", bytes: 8192)
    try fixture.plantDir("Library/Developer/CoreSimulator/Devices/decoy")
    try fixture.plantSymlink(at: "escape", to: "/")

    #expect(fixture.exists("Library/Developer/Xcode/DerivedData/Demo-abc/file.bin"))
    #expect(fixture.exists("Library/Developer/CoreSimulator/Devices/decoy"))
}

@Test func cacheItemIdentityIsCategoryPlusPath() {
    let a = CacheItem(categoryID: CategoryID("in-repo-build"), url: URL(filePath: "/x/ChessClock/build"), label: "build")
    let b = CacheItem(categoryID: CategoryID("in-repo-build"), url: URL(filePath: "/x/FaxApp/build"), label: "build")
    // Six repos on the reference machine have an item literally named
    // "build" — identity must come from the path, never the label.
    #expect(a.id != b.id)
}

@Test func recordingDeleterRecordsWithoutDeleting() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let file = try fixture.plantFile("Library/Caches/demo/payload.bin")

    let deleter = RecordingDeleter()
    let item = CacheItem(categoryID: CategoryID("demo"), url: file.deletingLastPathComponent(), label: "demo")
    let deleted = try await deleter.delete(DeletionRequest(item: item, allowedRoots: [fixture.url("Library/Caches")]))

    #expect(deleted == [item.url])
    #expect(fixture.exists("Library/Caches/demo/payload.bin"))
    let requests = await deleter.requests
    #expect(requests.count == 1)
}

@Test func sourcesSupportCleaningByDefault() {
    #expect(DefaultCleaningSource().supportsCleaning)
    #expect(!ViewOnlyContractSource().supportsCleaning)
}

@Test func scanRootDefaultsToFirstDeletionRootWithoutCreatingOneForViewOnlySources() {
    let context = ScanContext(home: URL(filePath: "/tmp/cruft-scan-root-contract"))
    let cleanable = DefaultCleaningSource()

    #expect(cleanable.scanRoot(context: context)
        == cleanable.allowedDeletionRoots(context: context).first)
    #expect(ViewOnlyContractSource().scanRoot(context: context) == nil)
}

@Test func viewOnlySourceRefusesDirectCleanBeforeDeletion() async {
    let source = ViewOnlyContractSource()
    let item = CacheItem(
        categoryID: source.id,
        url: URL(filePath: "/tmp/cruft-view-only-contract/item"),
        label: "item"
    )
    let deleter = RecordingDeleter()

    await #expect(throws: CacheSourceError.cleaningUnsupported(source.id)) {
        try await source.clean(
            item: item,
            context: ScanContext(home: URL(filePath: "/tmp/cruft-view-only-contract")),
            using: deleter
        )
    }
    #expect(await deleter.requests.isEmpty)
}
