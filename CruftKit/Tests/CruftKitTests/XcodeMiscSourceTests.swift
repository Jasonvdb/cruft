import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private func canonicalPath(_ url: URL) -> String {
    url.cruftCanonical.path(percentEncoded: false)
}

@Test func xcodeMiscDiscoversPlantedCacheRootsAsContentsOnly() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let xcodeCache = try fixture.plantXcodeCacheFixture()
    let simCaches = try fixture.plantSimulatorCachesFixture()
    try fixture.plantSimulatorDeviceDecoy()

    let items = try await XcodeMiscSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.categoryID == XcodeMiscSource.id })
    #expect(items.allSatisfy { $0.deletionMode == .contentsOnly })
    let labelsByPath = Dictionary(uniqueKeysWithValues: items.map { (canonicalPath($0.url), $0.label) })
    #expect(labelsByPath[canonicalPath(xcodeCache)] == "Xcode cache")
    #expect(labelsByPath[canonicalPath(simCaches)] == "Simulator caches")
}

@Test func xcodeMiscDiscoversOnlyTheRootsThatExist() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    let xcodeCache = try fixture.plantXcodeCacheFixture()
    try fixture.plantSimulatorDeviceDecoy()

    let items = try await XcodeMiscSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.count == 1)
    #expect(items.first.map { canonicalPath($0.url) } == canonicalPath(xcodeCache))
    #expect(items.first?.label == "Xcode cache")
}

@Test func xcodeMiscReturnsNothingWhenRootsAreMissing() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    // Devices exist (decoy), the cache roots do not — discovery must come
    // back empty without throwing.
    try fixture.plantSimulatorDeviceDecoy()

    let items = try await XcodeMiscSource().discover(context: ScanContext(home: fixture.root))

    #expect(items.isEmpty)
}

/// THE critical negative test for this source: simulator device data under
/// `CoreSimulator/Devices` is user data (additionally denylisted in
/// SafeDeleter) and must be invisible to this source in BOTH directions —
/// never discovered, and never inside any allowed deletion root.
@Test func xcodeMiscNeverDiscoversOrCoversSimulatorDevices() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantXcodeCacheFixture()
    try fixture.plantSimulatorCachesFixture()
    let deviceData = try fixture.plantSimulatorDeviceDecoy()

    let source = XcodeMiscSource()
    let context = ScanContext(home: fixture.root)
    let items = try await source.discover(context: context)
    let devicePath = canonicalPath(deviceData)

    // Never discovered: no item is the device data dir, contains it, or
    // sits inside it.
    #expect(!items.contains { canonicalPath($0.url).contains("/CoreSimulator/Devices") })
    #expect(!items.contains { devicePath.hasPrefix(canonicalPath($0.url) + "/") })
    #expect(!items.contains { canonicalPath($0.url).hasPrefix(devicePath) })

    // Never inside (or equal to) any allowed deletion root.
    for root in source.allowedDeletionRoots(context: context) {
        let rootPath = canonicalPath(root)
        #expect(devicePath != rootPath)
        #expect(!devicePath.hasPrefix(rootPath + "/"))
        #expect(!rootPath.contains("/CoreSimulator/Devices"))
    }
}

@Test func xcodeMiscAllowedRootsAreExactlyTheTwoCacheRoots() throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let roots = XcodeMiscSource().allowedDeletionRoots(context: ScanContext(home: fixture.root))

    #expect(roots.count == 2)
    #expect(Set(roots.map(canonicalPath)) == Set([
        canonicalPath(fixture.url("Library/Caches/com.apple.dt.Xcode")),
        canonicalPath(fixture.url("Library/Developer/CoreSimulator/Caches")),
    ]))
}

@Test func xcodeMiscCleanRoutesThroughTheDeleterSeam() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantXcodeCacheFixture()
    try fixture.plantSimulatorDeviceDecoy()

    let source = XcodeMiscSource()
    let context = ScanContext(home: fixture.root)
    let item = try #require(try await source.discover(context: context).first)
    let deleter = RecordingDeleter()

    let deleted = try await source.clean(item: item, context: context, using: deleter)

    #expect(deleted == [item.url])
    let requests = await deleter.requests
    #expect(requests.count == 1)
    #expect(requests.first?.item == item)
    #expect(requests.first.map { $0.allowedRoots.map(canonicalPath) }
        == source.allowedDeletionRoots(context: context).map(canonicalPath))
    // RecordingDeleter deletes nothing — the planted payload survives.
    #expect(fixture.exists("Library/Caches/com.apple.dt.Xcode/fsCachedData/payload.bin"))
}
