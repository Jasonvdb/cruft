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
    let source = DefaultCleaningSource()
    #expect(source.supportsCleaning)
    #expect(source.allowsWholeCategoryCleaning)
    #expect(source.destructiveWarning == nil)
    #expect(source.canClean(item: CacheItem(
        categoryID: source.id, url: URL(filePath: "/tmp/default-cleaning/item"), label: "item")))
    #expect(!source.canClean(item: CacheItem(
        categoryID: CategoryID("other"), url: URL(filePath: "/tmp/other/item"), label: "item")))
    #expect(!ViewOnlyContractSource().supportsCleaning)
    #expect(!ViewOnlyContractSource().allowsWholeCategoryCleaning)
}

@Test func cacheItemDecodesV2SnapshotWithoutSimulatorMetadata() throws {
    let original = CacheItem(
        categoryID: CategoryID("demo"),
        url: URL(filePath: "/tmp/cruft-v2/cache/item"),
        label: "item")
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CacheItem.self, from: encoded)

    #expect(decoded == original)
    #expect(decoded.simulatorMetadata == nil)
}

@Test func simulatorMetadataRoundTripsWithCacheItem() throws {
    let metadata = SimulatorDeviceMetadata(
        udid: "11111111-1111-4111-8111-111111111111",
        name: "Custom",
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        mainGroup: .other,
        runtimeLabel: "iOS 26.5",
        isBooted: false,
        isDeletable: true)
    let original = CacheItem(
        categoryID: SimulatorDeviceDataSource.id,
        url: URL(filePath: "/tmp/cruft-v3/device"),
        label: "Custom",
        deletionMode: .simulatorDevice,
        simulatorMetadata: metadata)

    let decoded = try JSONDecoder().decode(
        CacheItem.self, from: JSONEncoder().encode(original))

    #expect(decoded == original)
    #expect(decoded.simulatorMetadata == metadata)
    #expect(decoded.simulatorMetadata?.hasExactIdentity == true)
    #expect(decoded.simulatorMetadata?.isEligibleForDeletion == true)
}

@Test func cacheItemDecodesV3SimulatorMetadataWithoutV4IdentityFacts() throws {
    let original = CacheItem(
        categoryID: SimulatorDeviceDataSource.id,
        url: URL(filePath: "/tmp/cruft-v3/device"),
        label: "Custom",
        deletionMode: .simulatorDevice,
        simulatorMetadata: SimulatorDeviceMetadata(
            udid: "11111111-1111-4111-8111-111111111111",
            mainGroup: .other,
            runtimeLabel: "iOS 26.5",
            isBooted: false,
            isDeletable: true))

    let decoded = try JSONDecoder().decode(
        CacheItem.self, from: JSONEncoder().encode(original))

    #expect(decoded == original)
    #expect(decoded.simulatorMetadata?.name == nil)
    #expect(decoded.simulatorMetadata?.deviceTypeIdentifier == nil)
    #expect(decoded.simulatorMetadata?.runtimeIdentifier == nil)
    #expect(decoded.simulatorMetadata?.hasExactIdentity == false)
    #expect(decoded.simulatorMetadata?.isEligibleForDeletion == false)
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
