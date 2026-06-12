import Foundation

/// `~/Library/Developer/Xcode/Archives` — DESTRUCTIVE: archives contain
/// release dSYMs needed for crash symbolication and are NOT re-derivable.
/// Never in Clean All by default; per-category clean shows a strong warning.
///
/// Xcode lays archives out as `Archives/<YYYY-MM-DD>/<Name Date, Time>.xcarchive`;
/// discovery searches every first-level subdirectory for `.xcarchive` bundles
/// and also tolerates bundles sitting directly at the Archives root. Each
/// bundle is one `.entireItem`; the Archives directory itself always survives.
public struct ArchivesSource: CacheSource {
    public static let id = CategoryID("xcode-archives")
    public let displayName = "Xcode Archives"
    public let includedInCleanAllByDefault = false
    public let isDestructive = true

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [archivesRoot(in: context)]
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = archivesRoot(in: context)
        guard directoryExists(root) else { return [] }

        var items: [CacheItem] = []
        for child in try subdirectories(of: root) {
            if isArchiveBundle(child) {
                items.append(item(for: child))
            } else {
                // Date subdirectory (or any stray folder): archives live
                // exactly one level down; never recurse deeper.
                for grandchild in try subdirectories(of: child) where isArchiveBundle(grandchild) {
                    items.append(item(for: grandchild))
                }
            }
        }
        return items.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    private func archivesRoot(in context: ScanContext) -> URL {
        context.home.appending(path: "Library/Developer/Xcode/Archives")
    }

    private func item(for bundle: URL) -> CacheItem {
        CacheItem(
            categoryID: Self.id,
            url: bundle,
            label: bundle.deletingPathExtension().lastPathComponent,
            deletionMode: .entireItem
        )
    }

    /// An archive is a real directory bundle named `*.xcarchive`. Plain files
    /// or symlinks wearing the extension are never items.
    private func isArchiveBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "xcarchive"
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Shallow listing of the real subdirectories of `url` (files and
    /// symlinks excluded), throwing only on real errors such as EACCES on
    /// an existing directory. Children are rebuilt on the parent URL so
    /// item ids never embed `/private` prefixes or trailing slashes.
    private func subdirectories(of url: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: keys),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            return url.appending(path: entry.lastPathComponent)
        }
    }
}
