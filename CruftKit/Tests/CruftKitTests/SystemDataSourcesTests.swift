import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

// Tests for the v7 categories: /flow run artifacts, simulator runtimes, Xcode
// test clones, simulator logs, other DerivedData, Python caches, the opt-in
// live-use check, and the storage overview.

private let iphoneType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
private let ios264 = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
private let ios265 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
private let day: TimeInterval = 24 * 60 * 60

private struct FixedMeasurer: DirectoryMeasurer {
    let size: ItemSize

    func measure(_ root: URL, partial: @Sendable (ItemSize) -> Void) async throws -> ItemSize {
        size
    }
}

/// Reports a size per path suffix; unknown paths measure as zero.
private struct PathSizeMeasurer: DirectoryMeasurer {
    let sizes: [String: Int64]

    func measure(_ root: URL, partial: @Sendable (ItemSize) -> Void) async throws -> ItemSize {
        let path = root.path(percentEncoded: false)
        let bytes = sizes.first { path.hasSuffix($0.key) }?.value ?? 0
        return ItemSize(allocatedBytes: bytes, fileCount: 1)
    }
}

private struct StubUseChecker: GuardedArtifactUseChecking {
    let inUse: Bool
    func isInUse(_ target: URL) throws -> Bool { inUse }
}

private struct StubDeviceTypeNames: SimulatorDeviceTypeNameProviding {
    func standardNamesByIdentifier() -> [String: String] { [iphoneType: "iPhone 17 Pro"] }
}

private struct UnusedSimulatorRunner: SimulatorDeviceCommandRunning {
    func deleteSimulator(udid: String) throws {
        Issue.record("fixture homes must never call simctl delete")
    }
}

private final class RecordingToolRunner: SimulatorToolCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func deleteDevice(udid: String, inDeviceSet deviceSet: URL) throws {
        lock.lock()
        calls.append("device \(udid)")
        lock.unlock()
    }

    func deleteRuntime(identifier: String) throws {
        lock.lock()
        calls.append("runtime \(identifier)")
        lock.unlock()
    }
}

private struct StubRuntimeInventory: SimulatorRuntimeInventoryProviding {
    let records: [SimulatorRuntimeRecord]
    func runtimes(home: URL) throws -> [SimulatorRuntimeRecord] { records }
}

private struct StubQuerier: ProcessQuerying {
    var bundleIDs: Set<String> = []
    var commandLines: [String] = []

    func runningAppBundleIDs() -> Set<String> { bundleIDs }
    func processCommandLines() -> [String] { commandLines }
}

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func makeDeleter(
    home: URL,
    mode: SafeDeleter.Mode = .live,
    modifiedAt: Date = now.addingTimeInterval(-4 * day),
    inUse: Bool = false,
    toolRunner: RecordingToolRunner = RecordingToolRunner(),
    runtimes: [SimulatorRuntimeRecord] = []
) throws -> SafeDeleter {
    try SafeDeleter(
        home: home,
        mode: mode,
        simulatorCommandRunner: UnusedSimulatorRunner(),
        simulatorDeviceTypeNames: StubDeviceTypeNames(),
        guardedUseChecker: StubUseChecker(inUse: inUse),
        measurer: FixedMeasurer(size: ItemSize(
            allocatedBytes: 4096, fileCount: 1, newestModificationDate: modifiedAt)),
        now: { now },
        toolCommandRunner: toolRunner,
        runtimeInventory: StubRuntimeInventory(records: runtimes),
        runtimeRemovalTimeout: .milliseconds(10))
}

private func writeDevicePlist(
    _ fixture: FixtureHome, set: String, udid: String, runtime: String, state: Int,
    name: String = "iPhone 17 Pro"
) throws {
    try fixture.plantDir("\(set)/\(udid)/data")
    let metadata: [String: Any] = [
        "name": name, "deviceType": iphoneType, "runtime": runtime, "UDID": udid, "state": state,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
    try data.write(to: fixture.url("\(set)/\(udid)/device.plist"))
}

/// The SafeDeleter rule that refused `operation`, by case name, or nil.
private func refusedRule(_ operation: () async throws -> Void) async -> String? {
    do {
        try await operation()
        return nil
    } catch let error as SafeDeleterError {
        return String(describing: error).components(separatedBy: "(").first
    } catch {
        return "other: \(error)"
    }
}

private func measured(_ item: CacheItem, modifiedAt: Date?, errors: Int = 0) -> MeasuredItem {
    MeasuredItem(item: item, size: ItemSize(
        allocatedBytes: 4096, fileCount: 1, erroredEntries: errors, newestModificationDate: modifiedAt))
}

// MARK: - /flow run artifacts

@Suite("FlowRunArtifactSource")
struct FlowRunArtifactSourceTests {
    @Test func discoversRunsWithManifestFactsAndSkipsOddEntries() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantFlowRunFixture(runID: "claude-done-1", state: "merged")
        try fixture.plantFlowRunFixture(runID: "codex-live-2", state: "active", heartbeatAt: now)
        try fixture.plantFlowRunFixture(runID: "orphan-3", state: nil)
        try fixture.plantDir("private-tmp/flow-runs/bad name")
        try fixture.plantDir("private-tmp/flow-runs/.hidden")
        try fixture.plantSymlink(at: "private-tmp/flow-runs/linked-4", to: fixture.url("Documents").path(percentEncoded: false))

        let items = try await FlowRunArtifactSource().discover(context: ScanContext(home: fixture.root))

        #expect(items.map(\.label) == ["claude-done-1", "codex-live-2", "orphan-3"])
        #expect(items[0].flowRunMetadata?.state == "merged")
        #expect(items[0].flowRunMetadata?.isTerminal == true)
        #expect(items[1].flowRunMetadata?.isLive == true)
        #expect(items[2].flowRunMetadata?.hasManifest == false)
        #expect(items.allSatisfy { $0.deletionMode == .flowRunArtifacts })
    }

    @Test func manifestReaderTreatsAnythingOddAsMissing() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let reader = FlowRunManifestReader(stateDirectory: fixture.url(".local/state/flow-runs"))

        try fixture.writeFlowRunManifest(runID: "wrong-id", state: "merged", heartbeatAt: now, manifestRunID: "other")
        #expect(!reader.metadata(runID: "wrong-id").hasManifest)

        try fixture.writeFlowRunManifest(runID: "bool-schema", state: "merged", heartbeatAt: now, schemaVersion: true)
        #expect(!reader.metadata(runID: "bool-schema").hasManifest)

        try fixture.writeFlowRunManifest(runID: "real", state: "failed", heartbeatAt: now)
        try fixture.plantSymlink(
            at: ".local/state/flow-runs/linked.json",
            to: fixture.url(".local/state/flow-runs/real.json").path(percentEncoded: false))
        #expect(!reader.metadata(runID: "linked").hasManifest)

        let real = reader.metadata(runID: "real")
        #expect(real.state == "failed")
        #expect(real.heartbeatAt == now)
        #expect(!FlowRunManifestReader.isValidRunID("../escape"))
        #expect(!FlowRunManifestReader.isValidRunID("-leading"))
    }

    @Test func listRulesUseManifestStateBeforeAge() throws {
        let finished = CacheItem(
            categoryID: FlowRunArtifactSource.id, url: URL(filePath: "/tmp/flow-runs/a"), label: "a",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "a", state: "merged", heartbeatAt: now))
        let active = CacheItem(
            categoryID: FlowRunArtifactSource.id, url: URL(filePath: "/tmp/flow-runs/b"), label: "b",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "b", state: "active", heartbeatAt: now))
        let stale = CacheItem(
            categoryID: FlowRunArtifactSource.id, url: URL(filePath: "/tmp/flow-runs/c"), label: "c",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "c", state: "active", heartbeatAt: now.addingTimeInterval(-5 * day)))
        let orphan = CacheItem(
            categoryID: FlowRunArtifactSource.id, url: URL(filePath: "/tmp/flow-runs/d"), label: "d",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "d", state: nil, heartbeatAt: nil))

        let recent = now.addingTimeInterval(-60)
        let old = now.addingTimeInterval(-4 * day)
        #expect(GuardedCleanupList.blockingReasons(for: measured(finished, modifiedAt: recent), now: now).isEmpty)
        #expect(GuardedCleanupList.blockingReasons(for: measured(active, modifiedAt: old), now: now) == [.runActive])
        #expect(GuardedCleanupList.blockingReasons(for: measured(stale, modifiedAt: old), now: now).isEmpty)
        #expect(GuardedCleanupList.blockingReasons(for: measured(orphan, modifiedAt: recent), now: now) == [.recent])

        let list = GuardedCleanupList(snapshot: CategorySnapshot(
            categoryID: FlowRunArtifactSource.id,
            items: [measured(finished, modifiedAt: recent)]), now: now)
        #expect(list.rows.first?.readyNote == .finishedRun)
    }

    @Test func finishedRunDeletesWithoutAgeButStillChecksLiveUse() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantFlowRunFixture(runID: "claude-done", state: "merged", modifiedAt: now)
        let source = FlowRunArtifactSource()
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)

        let busy = try makeDeleter(home: fixture.root, modifiedAt: now, inUse: true)
        #expect(await refusedRule {
            try await source.clean(item: item, context: context, using: busy)
        } == "activeUseDetected")
        #expect(fixture.exists("private-tmp/flow-runs/claude-done"))

        let idle = try makeDeleter(home: fixture.root, modifiedAt: now)
        let deleted = try await source.clean(item: item, context: context, using: idle)
        #expect(deleted.count == 1)
        #expect(!fixture.exists("private-tmp/flow-runs/claude-done"))
        #expect(fixture.exists("private-tmp/flow-runs"))
        #expect(fixture.exists(".local/state/flow-runs/claude-done.json"))
    }

    @Test func activeChangedOrUnmanifestedRunsAreRefused() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantFlowRunFixture(runID: "live-run", state: "active", heartbeatAt: now.addingTimeInterval(-60))
        try fixture.plantFlowRunFixture(runID: "changing-run", state: "merged")
        try fixture.plantFlowRunFixture(runID: "orphan-run", state: nil, modifiedAt: now)
        let source = FlowRunArtifactSource()
        let context = ScanContext(home: fixture.root)
        let items = Dictionary(uniqueKeysWithValues: try await source.discover(context: context).map { ($0.label, $0) })
        let deleter = try makeDeleter(home: fixture.root, modifiedAt: now)

        let live = try #require(items["live-run"])
        #expect(await refusedRule {
            try await deleter.delete(DeletionRequest(item: live, allowedRoots: source.allowedDeletionRoots(context: context)))
        } == "flowRunActive")

        // The run was resumed after the scan: the manifest no longer matches.
        let changing = try #require(items["changing-run"])
        try fixture.writeFlowRunManifest(runID: "changing-run", state: "active", heartbeatAt: now)
        #expect(await refusedRule {
            try await deleter.delete(DeletionRequest(item: changing, allowedRoots: source.allowedDeletionRoots(context: context)))
        } == "guardedTargetInvalid")

        let orphan = try #require(items["orphan-run"])
        #expect(await refusedRule {
            try await deleter.delete(DeletionRequest(item: orphan, allowedRoots: source.allowedDeletionRoots(context: context)))
        } == "minimumAgeNotMet")
        #expect(fixture.exists("private-tmp/flow-runs/live-run"))
        #expect(fixture.exists("private-tmp/flow-runs/changing-run"))
        #expect(fixture.exists("private-tmp/flow-runs/orphan-run"))
    }

    @Test func flowRunModeRefusesOtherLocations() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantDir("Documents/claude-done")
        let item = CacheItem(
            categoryID: FlowRunArtifactSource.id,
            url: fixture.url("Documents/claude-done"),
            label: "claude-done",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "claude-done", state: "merged", heartbeatAt: nil))
        let deleter = try makeDeleter(home: fixture.root)
        #expect(await refusedRule {
            try await deleter.delete(DeletionRequest(item: item, allowedRoots: [fixture.url("Documents")]))
        } == "guardedTargetInvalid")
        #expect(fixture.exists("Documents/claude-done"))
    }
}

// MARK: - Simulator runtimes

@Suite("SimulatorRuntimeSource")
struct SimulatorRuntimeSourceTests {
    private static let listJSON = """
    {
      "A1": {"identifier": "11111111-1111-4111-8111-111111111111", "runtimeIdentifier": "\(ios264)",
             "version": "26.4", "build": "23E244", "state": "Ready", "deletable": true,
             "path": "/System/Library/AssetsV2/x/a.dmg", "lastUsedAt": "2026-04-17T08:20:59Z"},
      "A2": {"identifier": "22222222-2222-4222-8222-222222222222", "runtimeIdentifier": "\(ios265)",
             "version": "26.5", "build": "23F77", "state": "Ready", "deletable": true,
             "path": "/System/Library/AssetsV2/x/b.dmg"},
      "A3": {"identifier": "33333333-3333-4333-8333-333333333333",
             "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
             "version": "26.5", "build": "23T570", "state": "Ready", "deletable": true,
             "path": "/System/Library/AssetsV2/x/c.dmg"},
      "BAD": {"identifier": "not-a-uuid", "runtimeIdentifier": "\(ios264)",
              "version": "26.4", "build": "1", "state": "Ready", "path": "/x.dmg"}
    }
    """

    @Test func parserMarksNewestPerPlatformAndCountsDevices() throws {
        let images = try SimulatorRuntimeListParser.parse(Data(Self.listJSON.utf8))
        #expect(images.count == 3)
        let records = SimulatorRuntimeListParser.records(images: images, deviceCounts: [ios265: 4])
        let byBuild = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.build, $0.metadata) })

        let old = try #require(byBuild["23E244"])
        #expect(!old.isNewestForPlatform)
        #expect(old.deviceCount == 0)
        #expect(old.isEligibleForDeletion)
        #expect(old.label == "iOS 26.4 (23E244)")
        #expect(old.lastUsedAt != nil)

        let current = try #require(byBuild["23F77"])
        #expect(current.isNewestForPlatform)
        #expect(current.deviceCount == 4)
        #expect(!current.isEligibleForDeletion)

        let watch = try #require(byBuild["23T570"])
        #expect(watch.platformName == "watchOS")
        #expect(watch.isNewestForPlatform)
    }

    @Test func deviceCountsReadBothDeviceSets() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try writeDevicePlist(
            fixture, set: "Library/Developer/CoreSimulator/Devices",
            udid: "AAAAAAAA-0000-4000-8000-000000000001", runtime: ios264, state: 1)
        try writeDevicePlist(
            fixture, set: "Library/Developer/XCTestDevices",
            udid: "AAAAAAAA-0000-4000-8000-000000000002", runtime: ios264, state: 3)
        try fixture.plantDir("Library/Developer/CoreSimulator/Devices/BBBBBBBB-0000-4000-8000-000000000003")

        #expect(SimulatorRuntimeUsage.deviceCounts(home: fixture.root) == [ios264: 2])
        #expect(SimulatorRuntimeUsage.bootedDeviceUDIDs(home: fixture.root)
            == ["AAAAAAAA-0000-4000-8000-000000000002"])
    }

    @Test func productionSourceNeverQueriesSimctlForFixtureHomes() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        #expect(try await SimulatorRuntimeSource().discover(context: ScanContext(home: fixture.root)).isEmpty)
    }

    @Test func eligibleRuntimeDeletesOnlyAfterLiveRecheck() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let oldImage = try fixture.plantRuntimeImage(named: "old")
        let newImage = try fixture.plantRuntimeImage(named: "new")
        try fixture.plantFile("Elsewhere/stray.dmg")
        let records = try runtimeRecords(old: oldImage, new: newImage, stray: fixture.url("Elsewhere/stray.dmg"))
        let source = SimulatorRuntimeSource(inventory: StubRuntimeInventory(records: records))
        let context = ScanContext(home: fixture.root)

        let items = try await source.discover(context: context)
        #expect(items.map(\.label) == ["iOS 26.5 (23F77)", "iOS 26.4 (23E244)"])
        let old = try #require(items.first { $0.label.contains("26.4") })
        let new = try #require(items.first { $0.label.contains("26.5") })
        #expect(source.canClean(item: old))
        #expect(!source.canClean(item: new))

        // A simulator was created on the old runtime after the scan.
        let inUse = records.map { record in
            SimulatorRuntimeRecord(metadata: SimulatorRuntimeMetadata(
                identifier: record.metadata.identifier,
                runtimeIdentifier: record.metadata.runtimeIdentifier,
                platformName: record.metadata.platformName,
                version: record.metadata.version,
                build: record.metadata.build,
                state: record.metadata.state,
                isDeletableBySimctl: true,
                deviceCount: 1,
                isNewestForPlatform: record.metadata.isNewestForPlatform,
                lastUsedAt: nil), imageURL: record.imageURL)
        }
        let staleDeleter = try makeDeleter(home: fixture.root, runtimes: inUse)
        #expect(await refusedRule {
            try await source.clean(item: old, context: context, using: staleDeleter)
        } == "simulatorRuntimeInvalid")
        #expect(FileManager.default.fileExists(atPath: oldImage.path(percentEncoded: false)))

        let tools = RecordingToolRunner()
        let deleter = try makeDeleter(home: fixture.root, toolRunner: tools, runtimes: records)
        let deleted = try await source.clean(item: old, context: context, using: deleter)
        #expect(deleted.count == 1)
        #expect(!FileManager.default.fileExists(atPath: oldImage.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: newImage.path(percentEncoded: false)))
        #expect(tools.recorded.isEmpty, "fixture homes never call simctl")

        await #expect(throws: CacheSourceError.itemCleaningUnsupported(SimulatorRuntimeSource.id, new.id)) {
            try await source.clean(item: new, context: context, using: deleter)
        }
    }

    @Test func runtimeListRulesNeverUseAge() {
        func item(devices: Int, newest: Bool, state: String = "Ready") -> MeasuredItem {
            measured(CacheItem(
                categoryID: SimulatorRuntimeSource.id,
                url: URL(filePath: "/System/Library/AssetsV2/x.dmg"),
                label: "iOS",
                deletionMode: .simulatorRuntime,
                simulatorRuntimeMetadata: SimulatorRuntimeMetadata(
                    identifier: "11111111-1111-4111-8111-111111111111",
                    runtimeIdentifier: ios264, platformName: "iOS", version: "26.4",
                    build: "23E244", state: state, isDeletableBySimctl: true,
                    deviceCount: devices, isNewestForPlatform: newest, lastUsedAt: nil)),
                modifiedAt: now)
        }
        #expect(GuardedCleanupList.blockingReasons(for: item(devices: 0, newest: false), now: now).isEmpty)
        #expect(GuardedCleanupList.blockingReasons(for: item(devices: 2, newest: true), now: now)
            == [.runtimeInUse, .runtimeNewest])
        #expect(GuardedCleanupList.blockingReasons(for: item(devices: 0, newest: false, state: "Deleting"), now: now)
            == [.runtimeNotReady])
    }

    private func runtimeRecords(old: URL, new: URL, stray: URL) throws -> [SimulatorRuntimeRecord] {
        let images = [
            SimulatorRuntimeListParser.Image(
                identifier: "11111111-1111-4111-8111-111111111111", runtimeIdentifier: ios264,
                version: "26.4", build: "23E244", state: "Ready", deletable: true,
                path: old.path(percentEncoded: false), lastUsedAt: nil),
            SimulatorRuntimeListParser.Image(
                identifier: "22222222-2222-4222-8222-222222222222", runtimeIdentifier: ios265,
                version: "26.5", build: "23F77", state: "Ready", deletable: true,
                path: new.path(percentEncoded: false), lastUsedAt: nil),
            SimulatorRuntimeListParser.Image(
                identifier: "33333333-3333-4333-8333-333333333333", runtimeIdentifier: ios264,
                version: "26.4", build: "23E000", state: "Ready", deletable: true,
                path: stray.path(percentEncoded: false), lastUsedAt: nil),
        ]
        return SimulatorRuntimeListParser.records(images: images, deviceCounts: [:])
    }
}

// MARK: - Xcode test clones and simulator logs

@Suite("Test clones and simulator logs")
struct TestCloneAndLogTests {
    @Test func shutDownClonesAreEligibleAndBootedOnesAreNot() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let set = FixtureHome.testDeviceSetPath
        let idle = "CCCCCCCC-0000-4000-8000-000000000001"
        let booted = "CCCCCCCC-0000-4000-8000-000000000002"
        try writeDevicePlist(fixture, set: set, udid: idle, runtime: ios265, state: 1, name: "Clone 1 of iPhone 17 Pro")
        try writeDevicePlist(fixture, set: set, udid: booted, runtime: ios265, state: 3, name: "Clone 2 of iPhone 17 Pro")
        try fixture.plantFile("\(set)/device_set.plist")
        let source = TestDeviceCloneSource(deviceTypeNames: StubDeviceTypeNames())
        let context = ScanContext(home: fixture.root)

        let items = try await source.discover(context: context)
        #expect(items.count == 2)
        let idleItem = try #require(items.first { $0.url.lastPathComponent == idle })
        let bootedItem = try #require(items.first { $0.url.lastPathComponent == booted })
        #expect(source.canClean(item: idleItem))
        #expect(!source.canClean(item: bootedItem))

        // Clean All keeps only the eligible clone.
        let snapshot = CategorySnapshot(
            categoryID: source.id,
            items: items.map { MeasuredItem(item: $0, size: ItemSize(allocatedBytes: 4096)) })
        let plan = CleanPlanner(sources: [source]).planCleanAll(snapshots: [snapshot])
        #expect(plan.itemsByCategory[source.id]?.map(\.id) == [idleItem.id])

        let deleter = try makeDeleter(home: fixture.root)
        _ = try await source.clean(item: idleItem, context: context, using: deleter)
        #expect(!fixture.exists("\(set)/\(idle)"))
        #expect(fixture.exists("\(set)/\(booted)"))
    }

    @Test func cloneThatBootedAfterTheScanIsRefused() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let set = FixtureHome.testDeviceSetPath
        let udid = "CCCCCCCC-0000-4000-8000-000000000003"
        try writeDevicePlist(fixture, set: set, udid: udid, runtime: ios265, state: 1, name: "Clone 1 of iPhone 17 Pro")
        let source = TestDeviceCloneSource(deviceTypeNames: StubDeviceTypeNames())
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)

        try writeDevicePlist(fixture, set: set, udid: udid, runtime: ios265, state: 3, name: "Clone 1 of iPhone 17 Pro")
        let deleter = try makeDeleter(home: fixture.root)
        #expect(await refusedRule {
            try await source.clean(item: item, context: context, using: deleter)
        } == "simulatorBooted")
        #expect(fixture.exists("\(set)/\(udid)"))
    }

    @Test func cloneModeRefusesTheDefaultDeviceSet() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let udid = "CCCCCCCC-0000-4000-8000-000000000004"
        let devices = "Library/Developer/CoreSimulator/Devices"
        try writeDevicePlist(fixture, set: devices, udid: udid, runtime: ios265, state: 1, name: "Clone 1 of iPhone 17 Pro")
        let metadata = SimulatorDeviceMetadataReader().metadata(
            in: fixture.url("\(devices)/\(udid)"), leafUDID: udid,
            standardNames: StubDeviceTypeNames().standardNamesByIdentifier())
        let item = CacheItem(
            categoryID: TestDeviceCloneSource.id, url: fixture.url("\(devices)/\(udid)"),
            label: "Clone 1 of iPhone 17 Pro", deletionMode: .testDeviceClone, simulatorMetadata: metadata)
        let deleter = try makeDeleter(home: fixture.root)
        await #expect(throws: SafeDeleterError.self) {
            try await deleter.delete(DeletionRequest(item: item, allowedRoots: [fixture.url(devices)]))
        }
        #expect(fixture.exists("\(devices)/\(udid)"))
    }

    @Test func logsOfBootedSimulatorsAreLeftOut() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let booted = "DDDDDDDD-0000-4000-8000-000000000001"
        let idle = "DDDDDDDD-0000-4000-8000-000000000002"
        try writeDevicePlist(
            fixture, set: "Library/Developer/CoreSimulator/Devices", udid: booted, runtime: ios265, state: 3)
        try fixture.plantSimulatorLogsFixture(udid: booted)
        try fixture.plantSimulatorLogsFixture(udid: idle)

        let items = try await SimulatorLogsSource().discover(context: ScanContext(home: fixture.root))
        #expect(Set(items.map(\.label)) == ["CoreSimulator.log", idle])
    }
}

// MARK: - Other DerivedData, Python caches, live use

@Suite("Tool caches")
struct ToolCacheTests {
    @Test func otherDerivedDataNeedsTheBuildSignature() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantOtherDerivedDataFixture()
        try fixture.plantFile("Library/Caches/direct/DerivedData/Build/x.bin")
        try fixture.plantFile("Library/Caches/direct/DerivedData/Logs/build.log")

        let items = try await OtherDerivedDataSource().discover(context: ScanContext(home: fixture.root))
        #expect(items.map(\.label) == ["direct DerivedData", "s1s DerivedData"])
    }

    @Test func liveUseCheckGuardsOptedInGenericDeletions() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantPythonCacheFixture()
        let source = PythonCacheSource()
        let context = ScanContext(home: fixture.root)
        let items = try await source.discover(context: context)
        #expect(items.map(\.label) == ["uv cache", "pip cache"])
        let uv = try #require(items.first)

        let busy = try makeDeleter(home: fixture.root, inUse: true)
        #expect(await refusedRule {
            try await source.clean(item: uv, context: context, using: busy)
        } == "activeUseDetected")
        #expect(fixture.exists(".cache/uv/archive-v0/abc/pkg.py"))

        let idle = try makeDeleter(home: fixture.root)
        _ = try await source.clean(item: uv, context: context, using: idle)
        #expect(fixture.exists(".cache/uv"))
        #expect(!fixture.exists(".cache/uv/archive-v0"))
        #expect(!fixture.exists(".cache/uv/CACHEDIR.TAG"))

        // Sources that do not opt in never pay for the check.
        let plain = try makeDeleter(home: fixture.root, inUse: true)
        let pip = try #require(items.last)
        _ = try await plain.delete(DeletionRequest(
            item: pip, allowedRoots: source.allowedDeletionRoots(context: context), requiresLiveUseCheck: false))
        #expect(!fixture.exists("Library/Caches/pip/http-v2"))
    }

    @Test func processWarningsCoverCommandLineToolsAndPython() {
        let guardWith = ProcessGuard(querier: StubQuerier(commandLines: [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -scheme App",
            "/Users/me/.local/bin/uv run tool",
        ]))
        #expect(guardWith.warnings(for: [OtherDerivedDataSource.id]).count == 1)
        #expect(guardWith.warnings(for: [PythonCacheSource.id]).count == 1)
        #expect(ProcessGuard(querier: StubQuerier()).warnings(for: [PythonCacheSource.id]).isEmpty)
    }

    @Test func fileRootMeasuresAsItsOwnSize() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let image = try fixture.plantRuntimeImage(named: "image")
        let size = try await FoundationMeasurer().measure(image) { _ in }
        #expect(size.fileCount == 1)
        #expect(size.allocatedBytes >= 8192)
    }
}

// MARK: - Storage overview and contracts

@Suite("Storage overview and v7 contracts")
struct StorageOverviewAndContractTests {
    @Test func overviewMeasuresHomeAreasSortedAndFiltered() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        try fixture.plantFile("Library/Developer/Xcode/iOS DeviceSupport/iPhone 27.0/Symbols/a")
        try fixture.plantFile("Library/Android/sdk/platforms/a")
        try fixture.plantFile(".android/avd/Pixel.avd/disk.img")
        let gb: Int64 = 1024 * 1024 * 1024
        let probe = StorageOverviewProbe(
            home: fixture.root,
            includesSystemAreas: false,
            measurer: PathSizeMeasurer(sizes: [
                "iOS DeviceSupport": 6 * gb,
                "Library/Android/sdk": 9 * gb,
                ".android/avd": 1024,
            ]),
            swapUsedBytes: { 20 * gb })

        let overview = await probe.load(now: now)
        #expect(overview.entries.map(\.id) == ["android-sdk", "device-support"])
        #expect(overview.totalEntryBytes == 15 * gb)
        #expect(overview.measuredAt == now)
        #expect(overview.volumeTotalBytes != nil)
        #expect(!probe.areas().contains { $0.id == "macos-update" })
    }

    @Test func v6SnapshotsDecodeAndV7MetadataRoundTrips() throws {
        let legacy = Data("""
        {"id":"temporary-derived-data:/tmp/x","categoryID":"temporary-derived-data",
         "url":"file:///tmp/x","label":"x","deletionMode":"temporaryDerivedData"}
        """.utf8)
        let decoded = try JSONDecoder().decode(CacheItem.self, from: legacy)
        #expect(decoded.flowRunMetadata == nil)
        #expect(decoded.simulatorRuntimeMetadata == nil)

        let original = CacheItem(
            categoryID: FlowRunArtifactSource.id,
            url: URL(filePath: "/tmp/flow-runs/run"),
            label: "run",
            deletionMode: .flowRunArtifacts,
            flowRunMetadata: FlowRunMetadata(runID: "run", state: "merged", heartbeatAt: now))
        let roundTripped = try JSONDecoder().decode(
            CacheItem.self, from: JSONEncoder().encode(original))
        #expect(roundTripped == original)
    }
}
