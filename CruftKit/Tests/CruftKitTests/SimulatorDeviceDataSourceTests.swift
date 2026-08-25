import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private let simulatorDevicesPath = "Library/Developer/CoreSimulator/Devices"

@Suite("SimulatorDeviceDataSource")
struct SimulatorDeviceDataSourceTests {
    @Test func missingAndEmptyRootsReturnNoItems() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let source = SimulatorDeviceDataSource()
        let context = ScanContext(home: fixture.root)

        #expect(try await source.discover(context: context).isEmpty)
        try fixture.plantDir(simulatorDevicesPath)
        #expect(try await source.discover(context: context).isEmpty)
    }

    @Test func validDirectUUIDDirectoriesAreSortedAndUseSafeMetadataNames() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let firstUUID = "11111111-1111-4111-8111-111111111111"
        let secondUUID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        _ = try fixture.plantSimulatorDeviceDecoy(uuid: secondUUID, name: "iPhone 16 Pro")
        _ = try fixture.plantSimulatorDeviceDecoy(uuid: firstUUID)

        let items = try await SimulatorDeviceDataSource().discover(
            context: ScanContext(home: fixture.root))

        #expect(items.map(\.url.lastPathComponent) == [firstUUID, secondUUID])
        #expect(items.map(\.label) == [firstUUID, "iPhone 16 Pro"])
        #expect(items.allSatisfy { $0.categoryID == SimulatorDeviceDataSource.id })
        #expect(items.allSatisfy { $0.deletionMode == .entireItem })
    }

    @Test func unsafeMetadataNameFallsBackToUUID() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let uuid = "22222222-2222-4222-8222-222222222222"
        _ = try fixture.plantSimulatorDeviceDecoy(uuid: uuid, name: "unsafe/name")

        let item = try #require(try await SimulatorDeviceDataSource().discover(
            context: ScanContext(home: fixture.root)).first)

        #expect(item.label == uuid)
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

        let items = try await SimulatorDeviceDataSource().discover(
            context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
    }

    @Test func viewOnlySourceHasNoDeletionRoots() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let source = SimulatorDeviceDataSource()
        let context = ScanContext(home: fixture.root)

        #expect(source.allowedDeletionRoots(context: context).isEmpty)
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
            to: outside.url("Library/Developer/CoreSimulator").path(percentEncoded: false)
        )

        let items = try await SimulatorDeviceDataSource().discover(
            context: ScanContext(home: fixture.root))

        #expect(items.isEmpty)
        #expect(outside.exists(
            "\(simulatorDevicesPath)/8A1B2C3D-0000-4444-8888-CAFEBABED00D/data/Documents/precious.txt"))
    }

    @Test func directCleanRefusesWithoutCallingTheDeleter() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        _ = try fixture.plantSimulatorDeviceDecoy()
        let source = SimulatorDeviceDataSource()
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)
        let deleter = RecordingDeleter()

        await #expect(throws: CacheSourceError.cleaningUnsupported(source.id)) {
            try await source.clean(item: item, context: context, using: deleter)
        }
        #expect(await deleter.requests.isEmpty)
        #expect(fixture.exists(
            "\(simulatorDevicesPath)/8A1B2C3D-0000-4444-8888-CAFEBABED00D/data/Documents/precious.txt"))
    }

    @Test func categoryMetadataIsStableAndViewOnly() {
        let source = SimulatorDeviceDataSource()

        #expect(source.id == CategoryID("simulator-device-data"))
        #expect(source.displayName == "Simulator Device Data")
        #expect(!source.supportsCleaning)
        #expect(!source.includedInCleanAllByDefault)
        #expect(!source.isDestructive)
    }
}
