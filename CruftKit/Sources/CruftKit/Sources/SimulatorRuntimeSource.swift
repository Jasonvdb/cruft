import Foundation

/// One installed runtime image and the facts deletion depends on.
struct SimulatorRuntimeRecord: Sendable, Hashable {
    let metadata: SimulatorRuntimeMetadata
    /// The disk image `simctl runtime list` reports as `path`.
    let imageURL: URL
}

/// Injectable runtime inventory. Production asks `simctl runtime list` for the
/// images and reads each device's `device.plist` for runtime use. Tests
/// supply fixed records, so no test ever reaches the real simulator service.
protocol SimulatorRuntimeInventoryProviding: Sendable {
    func runtimes(home: URL) throws -> [SimulatorRuntimeRecord]
}

struct SystemSimulatorRuntimeInventory: SimulatorRuntimeInventoryProviding {
    enum InventoryError: Error, Equatable {
        case listFailed(String)
    }

    private let processRunner: any DirectProcessRunning

    init(processRunner: any DirectProcessRunning = BoundedDirectProcessRunner(timeout: 30)) {
        self.processRunner = processRunner
    }

    func runtimes(home: URL) throws -> [SimulatorRuntimeRecord] {
        let result = try processRunner.run(
            executable: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["simctl", "runtime", "list", "--json"])
        guard result.status == 0, !result.outputWasTruncated else {
            let message = String(decoding: result.standardError.prefix(512), as: UTF8.self)
            throw InventoryError.listFailed(message.isEmpty ? "simctl runtime list failed" : message)
        }
        let images = try SimulatorRuntimeListParser.parse(result.standardOutput)
        let usage = SimulatorRuntimeUsage.deviceCounts(home: home)
        return SimulatorRuntimeListParser.records(images: images, deviceCounts: usage)
    }
}

/// Counts registered devices per runtime identifier in the default device set
/// and Xcode's XCTestDevices set. It reads `device.plist` directly, so it
/// never creates a device set as a side effect.
enum SimulatorRuntimeUsage {
    static let deviceSetRelativePaths = [
        "Library/Developer/CoreSimulator/Devices",
        "Library/Developer/XCTestDevices",
    ]

    static func deviceCounts(home: URL) -> [String: Int] {
        var counts: [String: Int] = [:]
        let reader = SimulatorDeviceMetadataReader()
        for relativePath in deviceSetRelativePaths {
            let root = home.appending(path: relativePath)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                let metadata = reader.metadata(
                    in: entry, leafUDID: entry.lastPathComponent, standardNames: [:])
                guard let runtime = metadata.runtimeIdentifier else { continue }
                counts[runtime, default: 0] += 1
            }
        }
        return counts
    }

    /// UDIDs of booted devices in both sets — the simulators whose logs are
    /// still being written.
    static func bootedDeviceUDIDs(home: URL) -> Set<String> {
        var booted: Set<String> = []
        let reader = SimulatorDeviceMetadataReader()
        for relativePath in deviceSetRelativePaths {
            let root = home.appending(path: relativePath)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                let metadata = reader.metadata(
                    in: entry, leafUDID: entry.lastPathComponent, standardNames: [:])
                if metadata.isBooted {
                    booted.insert(entry.lastPathComponent.uppercased())
                }
            }
        }
        return booted
    }
}

/// Strict parser for `simctl runtime list --json`. Entries with missing or
/// odd fields are dropped, which only ever hides a runtime from cleanup.
enum SimulatorRuntimeListParser {
    struct Image: Sendable, Hashable {
        let identifier: String
        let runtimeIdentifier: String
        let version: String
        let build: String
        let state: String
        let deletable: Bool
        let path: String
        let lastUsedAt: Date?
    }

    private struct Entry: Decodable {
        let identifier: String?
        let runtimeIdentifier: String?
        let version: String?
        let build: String?
        let state: String?
        let deletable: Bool?
        let path: String?
        let lastUsedAt: String?
    }

    static func parse(_ data: Data) throws -> [Image] {
        let document = try JSONDecoder().decode([String: Entry].self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return document.values.compactMap { entry in
            guard let identifier = entry.identifier, UUID(uuidString: identifier) != nil,
                let runtimeIdentifier = entry.runtimeIdentifier,
                platformName(runtimeIdentifier) != nil,
                let version = entry.version, versionParts(version) != nil,
                let build = entry.build, !build.isEmpty, build.count <= 32,
                let state = entry.state,
                let path = entry.path, path.hasPrefix("/")
            else { return nil }
            return Image(
                identifier: identifier,
                runtimeIdentifier: runtimeIdentifier,
                version: version,
                build: build,
                state: state,
                deletable: entry.deletable == true,
                path: path,
                lastUsedAt: entry.lastUsedAt.flatMap(formatter.date(from:)))
        }
    }

    /// Joins images with device use. Every image whose version equals the
    /// highest installed version for its platform counts as newest.
    static func records(images: [Image], deviceCounts: [String: Int]) -> [SimulatorRuntimeRecord] {
        var newestByPlatform: [String: [Int]] = [:]
        for image in images {
            guard let platform = platformName(image.runtimeIdentifier),
                let parts = versionParts(image.version)
            else { continue }
            if let current = newestByPlatform[platform], !isGreater(parts, than: current) {
                continue
            }
            newestByPlatform[platform] = parts
        }
        return images.compactMap { image in
            guard let platform = platformName(image.runtimeIdentifier),
                let parts = versionParts(image.version)
            else { return nil }
            let newest = newestByPlatform[platform].map { !isGreater($0, than: parts) } ?? true
            let metadata = SimulatorRuntimeMetadata(
                identifier: image.identifier,
                runtimeIdentifier: image.runtimeIdentifier,
                platformName: platform,
                version: image.version,
                build: image.build,
                state: image.state,
                isDeletableBySimctl: image.deletable,
                deviceCount: deviceCounts[image.runtimeIdentifier] ?? 0,
                isNewestForPlatform: newest,
                lastUsedAt: image.lastUsedAt)
            return SimulatorRuntimeRecord(
                metadata: metadata,
                imageURL: URL(filePath: image.path))
        }
    }

    static func platformName(_ runtimeIdentifier: String) -> String? {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtimeIdentifier.hasPrefix(prefix) else { return nil }
        let platform = runtimeIdentifier.dropFirst(prefix.count)
            .split(separator: "-", maxSplits: 1).first.map(String.init)
        guard let platform, ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"].contains(platform)
        else { return nil }
        return platform == "xrOS" ? "visionOS" : platform
    }

    static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        return numbers
    }

    private static func isGreater(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

/// Installed simulator runtime images. A runtime is offered for deletion only
/// when no simulator in either device set uses its runtime identifier, it is
/// not the newest installed version for its platform, and `simctl` reports it
/// Ready and deletable. Deletion goes through `simctl runtime delete`, one
/// runtime at a time, never through Clean All.
public struct SimulatorRuntimeSource: CacheSource {
    public static let id = CategoryID("simulator-runtimes")
    public static let downloadNotice =
        "Xcode must download a deleted runtime again (several GB) before it can use it."
    public let displayName = "Simulator Runtimes"
    public let includedInCleanAllByDefault = false
    public let allowsWholeCategoryCleaning = false
    public let defersScheduledScanForRecentRootActivity = false

    /// Where runtime images live on a real Mac. Discovery accepts only images
    /// below these roots.
    static let systemImageRoots = [
        URL(filePath: "/System/Library/AssetsV2", directoryHint: .isDirectory),
        URL(filePath: "/Library/Developer/CoreSimulator", directoryHint: .isDirectory),
    ]
    static let fixtureImageRelativePath = "Library/Developer/CoreSimulator/RuntimeImages"

    private let inventory: any SimulatorRuntimeInventoryProviding
    /// Production inventory talks to the real simulator service, so it only
    /// ever runs for the real home. Injected test inventories run anywhere.
    private let realHomeOnly: Bool

    public init() {
        self.inventory = SystemSimulatorRuntimeInventory()
        self.realHomeOnly = true
    }

    init(inventory: any SimulatorRuntimeInventoryProviding) {
        self.inventory = inventory
        self.realHomeOnly = false
    }

    /// Used only for the local-volume gate. Image roots sit outside home.
    public func scanRoot(context: ScanContext) -> URL? {
        context.home.appending(path: "Library/Developer/CoreSimulator")
    }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        if FlowRunArtifactSource.isRealHome(context.home) {
            return Self.systemImageRoots
        }
        return [context.home.appending(path: Self.fixtureImageRelativePath)]
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id
            && item.deletionMode == .simulatorRuntime
            && item.simulatorRuntimeMetadata?.isEligibleForDeletion == true
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let isRealHome = FlowRunArtifactSource.isRealHome(context.home)
        if realHomeOnly, !isRealHome { return [] }
        let roots = allowedDeletionRoots(context: context).map(Self.normalizedPath)
        // No Xcode, or simctl unavailable: nothing to show, not a failure.
        // The deletion choke point still treats a failed query as a refusal.
        guard let records = try? inventory.runtimes(home: context.home) else { return [] }
        return records.compactMap { record in
            let path = Self.normalizedPath(record.imageURL)
            guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return nil }
            return CacheItem(
                categoryID: Self.id,
                url: record.imageURL,
                label: record.metadata.label,
                deletionMode: .simulatorRuntime,
                simulatorRuntimeMetadata: record.metadata)
        }
        .sorted { lhs, rhs in
            let left = lhs.simulatorRuntimeMetadata
            let right = rhs.simulatorRuntimeMetadata
            if left?.platformName != right?.platformName {
                return (left?.platformName ?? "") < (right?.platformName ?? "")
            }
            return lhs.label > rhs.label
        }
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
