import Foundation

/// Simulator clones that Xcode creates for parallel testing, in the
/// `~/Library/Developer/XCTestDevices` device set. Xcode makes new clones for
/// the next test run, so a shut-down clone holds nothing worth keeping. Each
/// clone is deleted through `simctl --set … delete`, which keeps the device
/// set registry consistent and refuses a booted clone.
public struct TestDeviceCloneSource: CacheSource {
    public static let id = CategoryID("xctest-devices")
    public let displayName = "Xcode Test Clones"

    static let devicesRelativePath = "Library/Developer/XCTestDevices"
    private let deviceTypeNames: any SimulatorDeviceTypeNameProviding

    public init() {
        self.deviceTypeNames = SystemSimulatorDeviceTypeNameProvider()
    }

    init(deviceTypeNames: any SimulatorDeviceTypeNameProviding) {
        self.deviceTypeNames = deviceTypeNames
    }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.devicesRelativePath)]
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id
            && item.deletionMode == .testDeviceClone
            && item.simulatorMetadata?.isEligibleForDeletion == true
    }

    /// Real, direct UUID directories only, classified by the same strict
    /// `device.plist` reader as simulator device data.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let declaredRoot = context.home.appending(path: Self.devicesRelativePath)
        let root = declaredRoot.cruftCanonical
        guard Self.normalizedPath(root) == Self.normalizedPath(declaredRoot),
            TemporaryDerivedDataValidator.isRealDirectory(root)
        else { return [] }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        let candidates = entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard !candidates.isEmpty else { return [] }
        let standardNames = deviceTypeNames.standardNamesByIdentifier()

        return candidates.compactMap { entry in
            let udid = entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { return nil }
            let directory = root.appending(path: udid)
            let metadata = SimulatorDeviceMetadataReader().metadata(
                in: directory, leafUDID: udid, standardNames: standardNames)
            return CacheItem(
                categoryID: Self.id,
                url: directory,
                label: metadata.name ?? udid,
                deletionMode: .testDeviceClone,
                simulatorMetadata: metadata)
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
