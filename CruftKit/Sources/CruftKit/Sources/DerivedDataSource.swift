import Foundation

/// `~/Library/Developer/Xcode/DerivedData` — items are the per-project
/// subdirectories plus ModuleCache.noindex, each `.entireItem`; the
/// DerivedData directory itself always survives.
public struct DerivedDataSource: CacheSource {
    public static let id = CategoryID("derived-data")
    public let displayName = "Xcode DerivedData"

    public init() {}

    /// Every deletion for this category lives directly under the
    /// DerivedData directory; the Xcode siblings (Archives, iOS
    /// DeviceSupport) and CoreSimulator are outside this root by
    /// construction, so SafeDeleter refuses them automatically.
    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [derivedDataRoot(in: context)]
    }

    /// One item per direct child DIRECTORY of the root — per-project
    /// granularity ("MockupCreator-abcdef"), with the shared
    /// `ModuleCache.noindex` / `SymbolCache.noindex` caches naturally
    /// included. Non-directory children (`.lock` files, stray plists) are
    /// not items, and symlinked children are excluded so an item can never
    /// point outside the root. A missing root means nothing to clean — not
    /// an error.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = derivedDataRoot(in: context)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys))
        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: keys)
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .map { child in
                // contentsOfDirectory returns /private-prefixed,
                // trailing-slash URLs; rebuild on the canonical parent so
                // CacheItem.id never embeds a trailing slash (StatsStore and
                // CLI --exclude match on ids).
                CacheItem(
                    categoryID: Self.id,
                    url: root.appending(path: child.lastPathComponent),
                    label: child.lastPathComponent,
                    deletionMode: .entireItem
                )
            }
            .sorted { $0.label < $1.label }
    }

    private func derivedDataRoot(in context: ScanContext) -> URL {
        context.home.appending(path: "Library/Developer/Xcode/DerivedData")
    }
}
