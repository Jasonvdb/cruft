import Foundation

/// Simulator device directories can consume substantial storage, but they
/// contain installed apps and user data that cannot be re-derived. This
/// source measures each direct device directory for visibility only. It does
/// not expose a deletion root or support cleaning.
public struct SimulatorDeviceDataSource: CacheSource {
    public static let id = CategoryID("simulator-device-data")
    public let displayName = "Simulator Device Data"
    public let includedInCleanAllByDefault = false
    public let supportsCleaning = false

    private static let devicesRelativePath = "Library/Developer/CoreSimulator/Devices"
    private static let maximumMetadataBytes = 64 * 1024
    private static let maximumDeviceNameLength = 80

    public init() {}

    /// This source is view only. No path is valid for deletion.
    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        []
    }

    /// Discovers only real, direct UUID-named directories. It does not follow
    /// symlinks or search below non-device entries.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.home.appending(path: Self.devicesRelativePath)
        guard isRealDirectory(root) else { return [] }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return entries.compactMap { entry in
            let uuid = entry.lastPathComponent
            guard UUID(uuidString: uuid) != nil,
                let values = try? entry.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { return nil }

            // Rebuild from the known root. This keeps item identity stable
            // and avoids adopting an alternate spelling returned by listing.
            let directory = root.appending(path: uuid)
            return CacheItem(
                categoryID: Self.id,
                url: directory,
                label: safeDeviceName(in: directory) ?? uuid,
                deletionMode: .entireItem
            )
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Reads only the small metadata plist directly inside the device root.
    /// Payload files and nested metadata are never inspected for labels.
    private func safeDeviceName(in directory: URL) -> String? {
        let metadata = directory.appending(path: "device.plist")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? metadata.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= Self.maximumMetadataBytes,
            let data = try? Data(contentsOf: metadata),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let name = dictionary["name"] as? String,
            !name.isEmpty,
            name.count <= Self.maximumDeviceNameLength,
            name == name.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.contains("/"),
            name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }
}
