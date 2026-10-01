import Foundation

/// CoreSimulator's per-device log folders under `~/Library/Logs/CoreSimulator`.
/// Logs are never needed to run a simulator. Folders that belong to a booted
/// simulator in either device set are left out, because that simulator is
/// still writing into them.
public struct SimulatorLogsSource: CacheSource {
    public static let id = CategoryID("simulator-logs")
    public let displayName = "Simulator Logs"
    /// A running simulator writes here constantly; age is not a signal.
    public let defersScheduledScanForRecentRootActivity = false

    private static let logsRelativePath = "Library/Logs/CoreSimulator"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.logsRelativePath)]
    }

    /// Direct children only, each its own `.entireItem`. Symlinks are listed
    /// as links and SafeDeleter removes the link, never its destination.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.home.appending(path: Self.logsRelativePath)
        guard TemporaryDerivedDataValidator.isRealDirectory(root) else { return [] }
        let booted = SimulatorRuntimeUsage.bootedDeviceUDIDs(home: context.home)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard !booted.contains(name.uppercased()) else { return nil }
            return CacheItem(categoryID: Self.id, url: root.appending(path: name), label: name)
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }
}
