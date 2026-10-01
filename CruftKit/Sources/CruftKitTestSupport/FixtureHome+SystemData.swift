import Foundation

/// Recipes for the v7 categories: other DerivedData, /flow run artifacts,
/// the CoreDevice install cache, simulator logs, Xcode test clones, simulator
/// runtimes, and Python caches.
extension FixtureHome {
    public static let flowRunFixtureID = "claude-demo-flow-20260101T000000Z-abc123"
    public static let testDeviceSetPath = "Library/Developer/XCTestDevices"
    public static let deviceInstallCachePath =
        "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas"
    public static let runtimeImagesPath = "Library/Developer/CoreSimulator/RuntimeImages"

    // MARK: - Other DerivedData

    /// One tool cache with an Xcode-shaped DerivedData project (1 item), a
    /// tool `DerivedData` without the build signature, and Apple's own cache
    /// folder with a DerivedData child (both decoys).
    @discardableResult
    public func plantOtherDerivedDataFixture(tool: String = "s1s") throws -> URL {
        try plantFile("Library/Caches/\(tool)/DerivedData/Demo-abcdef/Build/Products/app.bin")
        try plantFile("Library/Caches/\(tool)/DerivedData/Demo-abcdef/info.plist")
        try plantFile("Library/Caches/plaintool/DerivedData/notes.txt")
        try plantFile("Library/Caches/com.apple.example/DerivedData/Demo/Build/x.bin")
        try plantFile("Library/Caches/com.apple.example/DerivedData/Demo/info.plist")
        return url("Library/Caches/\(tool)/DerivedData")
    }

    // MARK: - /flow run artifacts

    /// One run directory with a DerivedData build inside, plus its manifest.
    /// `state: nil` plants no manifest at all.
    @discardableResult
    public func plantFlowRunFixture(
        runID: String = Self.flowRunFixtureID,
        state: String? = "merged",
        heartbeatAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> URL {
        let root = try plantDir("private-tmp/flow-runs/\(runID)")
        try plantFile("private-tmp/flow-runs/\(runID)/DerivedData/Build/result.bin")
        try plantFile("private-tmp/flow-runs/\(runID)/screenshots/home.png")
        try setModificationDateRecursively(modifiedAt, at: root)
        if let state {
            try writeFlowRunManifest(runID: runID, state: state, heartbeatAt: heartbeatAt)
        }
        return root
    }

    public func writeFlowRunManifest(
        runID: String,
        state: String,
        heartbeatAt: Date?,
        schemaVersion: Any = 1,
        manifestRunID: String? = nil
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var manifest: [String: Any] = [
            "schemaVersion": schemaVersion,
            "runId": manifestRunID ?? runID,
            "state": state,
            "artifactRoot": "/private/tmp/flow-runs/\(runID)",
        ]
        if let heartbeatAt {
            manifest["heartbeatAt"] = formatter.string(from: heartbeatAt)
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try plantDir(".local/state/flow-runs")
        try data.write(to: url(".local/state/flow-runs/\(runID).json"))
    }

    // MARK: - CoreDevice install cache

    @discardableResult
    public func plantDeviceInstallCacheFixture() throws -> URL {
        try plantFile("\(Self.deviceInstallCachePath)/com.example.app/delta.bin")
        return url(Self.deviceInstallCachePath)
    }

    // MARK: - Simulator logs

    /// One per-device log folder and one loose log file (2 items).
    @discardableResult
    public func plantSimulatorLogsFixture(
        udid: String = "5E5E5E5E-0000-4444-8888-0123456789AB"
    ) throws -> URL {
        try plantFile("Library/Logs/CoreSimulator/\(udid)/system.log")
        try plantFile("Library/Logs/CoreSimulator/CoreSimulator.log")
        return url("Library/Logs/CoreSimulator")
    }

    // MARK: - Xcode test clones

    /// One clone directory in the XCTestDevices set. Without metadata it is
    /// unclassified, so it is visible but never eligible. The set's own
    /// registry file is a decoy.
    @discardableResult
    public func plantTestDeviceClone(
        uuid: String = "7C7C7C7C-0000-4444-8888-FEEDFACE0001",
        name: String? = nil,
        deviceType: String? = nil,
        runtime: String? = nil,
        state: Int? = nil
    ) throws -> URL {
        try plantFile("\(Self.testDeviceSetPath)/\(uuid)/data/Library/test.bin")
        try plantFile("\(Self.testDeviceSetPath)/device_set.plist")
        let values: [(String, Any?)] = [
            ("name", name), ("deviceType", deviceType), ("runtime", runtime),
            ("UDID", name == nil ? nil : uuid), ("state", state),
        ]
        let dictionary = Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            value.map { (key, $0) }
        })
        if !dictionary.isEmpty {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dictionary, format: .xml, options: 0)
            try data.write(to: url("\(Self.testDeviceSetPath)/\(uuid)/device.plist"))
        }
        return url("\(Self.testDeviceSetPath)/\(uuid)")
    }

    // MARK: - Simulator runtimes

    /// A stand-in runtime disk image inside the fixture home.
    @discardableResult
    public func plantRuntimeImage(named name: String) throws -> URL {
        try plantFile("\(Self.runtimeImagesPath)/\(name).dmg", bytes: 8192)
    }

    // MARK: - Python caches

    /// uv and pip caches (2 items).
    public func plantPythonCacheFixture() throws {
        try plantFile(".cache/uv/archive-v0/abc/pkg.py")
        try plantFile(".cache/uv/CACHEDIR.TAG")
        try plantFile("Library/Caches/pip/http-v2/a/b/blob")
    }
}
