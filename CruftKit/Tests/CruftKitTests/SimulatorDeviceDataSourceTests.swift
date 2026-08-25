import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private let simulatorDevicesPath = "Library/Developer/CoreSimulator/Devices"
private let iphoneType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
private let watchType = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm"
private let ios264 = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
private let watchOS265 = "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"

private struct StubDeviceTypeNames: SimulatorDeviceTypeNameProviding {
    var names: [String: String] = [
        iphoneType: "iPhone 17 Pro",
        watchType: "Apple Watch Series 11 (46mm)",
    ]

    func standardNamesByIdentifier() -> [String: String] { names }
}

private func testSource(names: [String: String]? = nil) -> SimulatorDeviceDataSource {
    SimulatorDeviceDataSource(
        deviceTypeNames: StubDeviceTypeNames(names: names ?? StubDeviceTypeNames().names))
}

@Suite("SimulatorDeviceDataSource")
struct SimulatorDeviceDataSourceTests {
    @Test func missingAndEmptyRootsReturnNoItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let source = testSource()
        let context = ScanContext(home: fixture.root)

        #expect(try await source.discover(context: context).isEmpty)
        try fixture.plantDir(simulatorDevicesPath)
        #expect(try await source.discover(context: context).isEmpty)
    }

    @Test func classifiesStandardAndCustomNamesByRuntimeAndBootState() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let xcodeUDID = "11111111-1111-4111-8111-111111111111"
        let flowUDID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: flowUDID,
            name: "SaySolid-feature-iPad",
            deviceType: watchType,
            runtime: watchOS265,
            metadataUDID: flowUDID,
            state: 3)
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: xcodeUDID,
            name: "iPhone 17 Pro",
            deviceType: iphoneType,
            runtime: ios264,
            metadataUDID: xcodeUDID,
            state: 1)

        let items = try await testSource().discover(context: ScanContext(home: fixture.root))

        #expect(items.map(\.url.lastPathComponent) == [xcodeUDID, flowUDID])
        #expect(items.map(\.label) == ["iPhone 17 Pro", "SaySolid-feature-iPad"])
        #expect(items.map(\.simulatorMetadata?.mainGroup) == [.xcode, .other])
        #expect(items.map(\.simulatorMetadata?.runtimeLabel) == ["iOS 26.4", "watchOS 26.5"])
        #expect(items[0].simulatorMetadata?.isBooted == false)
        #expect(items[0].simulatorMetadata?.isDeletable == true)
        #expect(items[1].simulatorMetadata?.isBooted == true)
        #expect(items[1].simulatorMetadata?.isDeletable == false)
        #expect(items.allSatisfy { $0.deletionMode == .simulatorDevice })
        #expect(testSource().canClean(item: items[0]))
        #expect(!testSource().canClean(item: items[1]))
    }

    @Test func missingMalformedMismatchedAndUnresolvedMetadataStayUnknown() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let missing = "11111111-1111-4111-8111-111111111111"
        let malformed = "22222222-2222-4222-8222-222222222222"
        let mismatch = "33333333-3333-4333-8333-333333333333"
        let unresolved = "44444444-4444-4444-8444-444444444444"
        _ = try fixture.plantSimulatorDeviceDecoy(uuid: missing)
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: malformed, name: "unsafe/name", deviceType: iphoneType,
            runtime: "bad-runtime", metadataUDID: malformed, state: 1)
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: mismatch, name: "iPhone 17 Pro", deviceType: iphoneType,
            runtime: ios264, metadataUDID: missing, state: 1)
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: unresolved, name: "Custom", deviceType: "unknown-type",
            runtime: ios264, metadataUDID: unresolved, state: 1)

        let items = try await testSource().discover(context: ScanContext(home: fixture.root))

        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.simulatorMetadata?.mainGroup == .unknown })
        #expect(items.allSatisfy { $0.simulatorMetadata?.isDeletable == false })
        #expect(items.first { $0.url.lastPathComponent == malformed }?.label == malformed)
        #expect(items.first { $0.url.lastPathComponent == mismatch }?
            .simulatorMetadata?.runtimeLabel == "iOS 26.4")
    }

    @Test func invalidDirectoriesFilesSymlinksAndNestedUUIDsAreIgnored() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let fileUUID = "33333333-3333-4333-8333-333333333333"
        let linkUUID = "44444444-4444-4444-8444-444444444444"
        let nestedUUID = "55555555-5555-4555-8555-555555555555"
        try fixture.plantDir("\(simulatorDevicesPath)/not-a-uuid")
        try fixture.plantFile("\(simulatorDevicesPath)/\(fileUUID)")
        let linkTarget = try fixture.plantDir("outside-simulator-devices")
        try fixture.plantSymlink(
            at: "\(simulatorDevicesPath)/\(linkUUID)",
            to: linkTarget.path(percentEncoded: false))
        try fixture.plantDir("\(simulatorDevicesPath)/not-a-uuid/\(nestedUUID)")

        #expect(try await testSource().discover(
            context: ScanContext(home: fixture.root)).isEmpty)
    }

    @Test func deletionRootIsExactDevicesDirectory() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let source = testSource()
        let context = ScanContext(home: fixture.root)

        #expect(source.allowedDeletionRoots(context: context) == [fixture.url(simulatorDevicesPath)])
        #expect(source.scanRoot(context: context) == fixture.url(simulatorDevicesPath))
    }

    @Test func intermediateParentSymlinkIsNotFollowedOutsideHome() async throws {
        let fixture = try FixtureHome.makeTemporary()
        let outside = try FixtureHome.makeTemporary()
        defer {
            try? fixture.destroy()
            try? outside.destroy()
        }
        _ = try outside.plantSimulatorDeviceDecoy()
        try fixture.plantDir("Library/Developer")
        try fixture.plantSymlink(
            at: "Library/Developer/CoreSimulator",
            to: outside.url("Library/Developer/CoreSimulator").path(percentEncoded: false))

        let items = try await testSource().discover(context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
        #expect(outside.exists(
            "\(simulatorDevicesPath)/8A1B2C3D-0000-4444-8888-CAFEBABED00D/data/Documents/precious.txt"))
    }

    @Test func unknownItemRefusesBeforeCallingDeleter() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        _ = try fixture.plantSimulatorDeviceDecoy()
        let source = testSource()
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)
        let deleter = RecordingDeleter()

        await #expect(throws: CacheSourceError.itemCleaningUnsupported(source.id, item.id)) {
            try await source.clean(item: item, context: context, using: deleter)
        }
        #expect(await deleter.requests.isEmpty)
    }

    @Test func eligibleExactItemRoutesThroughDeletionSeam() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let udid = "11111111-1111-4111-8111-111111111111"
        _ = try fixture.plantSimulatorDeviceDecoy(
            uuid: udid, name: "iPhone 17 Pro", deviceType: iphoneType,
            runtime: ios264, metadataUDID: udid, state: 1)
        let source = testSource()
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)
        let deleter = RecordingDeleter()

        let urls = try await source.clean(item: item, context: context, using: deleter)

        #expect(urls == [item.url])
        #expect(await deleter.requests.count == 1)
        #expect(fixture.exists("\(simulatorDevicesPath)/\(udid)"))
    }

    @Test func categoryMetadataIsStableAndSubgroupOnly() {
        let source = testSource()

        #expect(source.id == CategoryID("simulator-device-data"))
        #expect(source.displayName == "Simulator Device Data")
        #expect(source.supportsCleaning)
        #expect(!source.allowsWholeCategoryCleaning)
        #expect(!source.includedInCleanAllByDefault)
        #expect(source.isDestructive)
        #expect(source.destructiveWarning == SimulatorDeviceDataSource.warning)
    }
}
