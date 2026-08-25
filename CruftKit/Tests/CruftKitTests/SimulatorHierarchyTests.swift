import Foundation
import Testing
@testable import CruftKit

private func simulatorItem(
    index: Int,
    name: String,
    mainGroup: SimulatorDeviceMetadata.MainGroup,
    runtime: String,
    bytes: Int64,
    isBooted: Bool = false,
    isDeletable: Bool = true
) -> MeasuredItem {
    let udid = String(format: "00000000-0000-4000-8000-%012d", index)
    return MeasuredItem(
        item: CacheItem(
            categoryID: SimulatorDeviceDataSource.id,
            url: URL(filePath: "/tmp/fixture/CoreSimulator/Devices/\(udid)"),
            label: name,
            deletionMode: .simulatorDevice,
            simulatorMetadata: SimulatorDeviceMetadata(
                udid: udid,
                mainGroup: mainGroup,
                runtimeLabel: runtime,
                isBooted: isBooted,
                isDeletable: isDeletable)),
        size: ItemSize(allocatedBytes: bytes, fileCount: 1))
}

private func hierarchy(_ items: [MeasuredItem]) -> SimulatorHierarchy {
    SimulatorHierarchy(snapshot: CategorySnapshot(
        categoryID: SimulatorDeviceDataSource.id,
        items: items,
        updatedAt: Date()))
}

@Test func simulatorHierarchyAlwaysHasXcodeAndOtherAndSortsRuntimes() throws {
    let result = hierarchy([
        simulatorItem(
            index: 1, name: "iOS-old-a", mainGroup: .xcode,
            runtime: "iOS 26.4", bytes: 100),
        simulatorItem(
            index: 2, name: "iOS-old-b", mainGroup: .xcode,
            runtime: "iOS 26.4", bytes: 200),
        simulatorItem(
            index: 3, name: "iOS-new", mainGroup: .xcode,
            runtime: "iOS 26.10", bytes: 300),
        simulatorItem(
            index: 4, name: "watch", mainGroup: .xcode,
            runtime: "watchOS 26.5", bytes: 400),
        simulatorItem(
            index: 5, name: "SaySolid-flow-iPhone", mainGroup: .other,
            runtime: "iOS 26.5", bytes: 500),
    ])

    #expect(result.sections.map(\.displayName) == ["Xcode", "Other"])
    let xcode = try #require(result.sections.first { $0.mainGroup == .xcode })
    #expect(xcode.runtimeGroups.map(\.runtimeLabel)
        == ["iOS 26.10", "iOS 26.4", "watchOS 26.5"])
    let old = try #require(xcode.runtimeGroups.first { $0.runtimeLabel == "iOS 26.4" })
    #expect(old.deviceCount == 2)
    #expect(old.allocatedBytes == 300)
    #expect(old.isDeletable)

    let other = try #require(result.sections.first { $0.mainGroup == .other })
    #expect(other.runtimeGroups.map(\.runtimeLabel) == ["iOS 26.5"])
}

@Test func oneBlockedDeviceDisablesTheWholeRuntimeGroup() throws {
    let result = hierarchy([
        simulatorItem(
            index: 1, name: "ready", mainGroup: .other,
            runtime: "iOS 26.5", bytes: 100),
        simulatorItem(
            index: 2, name: "booted", mainGroup: .other,
            runtime: "iOS 26.5", bytes: 200, isBooted: true, isDeletable: false),
    ])
    let other = try #require(result.sections.first { $0.mainGroup == .other })
    let group = try #require(other.runtimeGroups.first)

    #expect(group.deviceCount == 2)
    #expect(group.allocatedBytes == 300)
    #expect(!group.isDeletable)
    #expect(group.blockingReasons == [.booted])
    #expect(group.measuredItems.count == 2, "a blocked group must not become a partial selection")
}

@Test func oldSnapshotWithoutMetadataAppearsAsOtherUnknownAndCannotDelete() throws {
    let measured = MeasuredItem(
        item: CacheItem(
            categoryID: SimulatorDeviceDataSource.id,
            url: URL(filePath: "/tmp/fixture/CoreSimulator/Devices/legacy"),
            label: "Legacy simulator",
            deletionMode: .simulatorDevice),
        size: ItemSize(allocatedBytes: 4096, fileCount: 1))
    let result = hierarchy([measured])

    let xcode = try #require(result.sections.first { $0.mainGroup == .xcode })
    #expect(xcode.runtimeGroups.isEmpty)
    let other = try #require(result.sections.first { $0.mainGroup == .other })
    let unknown = try #require(other.runtimeGroups.first)
    #expect(unknown.runtimeLabel == "Unknown")
    #expect(unknown.blockingReasons == [.unknownMetadata])
    #expect(!unknown.isDeletable)
}

@Test func unknownAndNotReadyReasonsAreStable() throws {
    let result = hierarchy([
        simulatorItem(
            index: 1, name: "unclassified", mainGroup: .unknown,
            runtime: "iOS 26.5", bytes: 100, isDeletable: false),
        simulatorItem(
            index: 2, name: "transitioning", mainGroup: .other,
            runtime: "watchOS 26.5", bytes: 200, isDeletable: false),
        simulatorItem(
            index: 3, name: "missing-runtime", mainGroup: .other,
            runtime: "", bytes: 300),
    ])
    let other = try #require(result.sections.first { $0.mainGroup == .other })
    let ios = try #require(other.runtimeGroups.first { $0.runtimeLabel == "iOS 26.5" })
    let watch = try #require(other.runtimeGroups.first { $0.runtimeLabel == "watchOS 26.5" })
    let unknown = try #require(other.runtimeGroups.first { $0.runtimeLabel == "Unknown" })

    #expect(ios.blockingReasons == [.unknownMetadata])
    #expect(watch.blockingReasons == [.notReady])
    #expect(unknown.blockingReasons == [.unknownMetadata])
    #expect(!ios.isDeletable)
    #expect(!watch.isDeletable)
    #expect(!unknown.isDeletable)
}

@Test func simulatorSnapshotRemainderPreservesUntouchedGroupsAndBytes() throws {
    let deleted = simulatorItem(
        index: 1, name: "old-a", mainGroup: .xcode,
        runtime: "iOS 26.4", bytes: 100)
    let oldRemaining = simulatorItem(
        index: 2, name: "old-b", mainGroup: .xcode,
        runtime: "iOS 26.4", bytes: 200)
    let customRemaining = simulatorItem(
        index: 3, name: "Flow-new", mainGroup: .other,
        runtime: "iOS 26.5", bytes: 500)
    let original = CategorySnapshot(
        categoryID: SimulatorDeviceDataSource.id,
        items: [deleted, oldRemaining, customRemaining],
        updatedAt: Date())

    let remainder = SimulatorHierarchy.remainingSnapshot(
        from: original,
        deletingPaths: [deleted.item.url.path(percentEncoded: false) + "/"])
    let result = SimulatorHierarchy(snapshot: remainder)

    #expect(remainder.items.map(\.item.id) == [oldRemaining.item.id, customRemaining.item.id])
    #expect(remainder.totalBytes == 700)
    let xcode = try #require(result.sections.first { $0.mainGroup == .xcode })
    let oldRuntime = try #require(
        xcode.runtimeGroups.first { $0.runtimeLabel == "iOS 26.4" })
    #expect(oldRuntime.deviceCount == 1)
    #expect(oldRuntime.allocatedBytes == 200)
    let other = try #require(result.sections.first { $0.mainGroup == .other })
    let newRuntime = try #require(
        other.runtimeGroups.first { $0.runtimeLabel == "iOS 26.5" })
    #expect(newRuntime.deviceCount == 1)
    #expect(newRuntime.allocatedBytes == 500)
}
