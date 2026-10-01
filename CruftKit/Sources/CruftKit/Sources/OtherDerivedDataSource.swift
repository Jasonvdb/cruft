import Foundation

/// Xcode DerivedData that a tool keeps in its own cache folder, such as
/// `~/Library/Caches/s1s/DerivedData`. Only a folder named `DerivedData`
/// directly inside a tool's cache folder is considered, and only when it has
/// Xcode's build-folder signature. A live-use check runs before deletion, so
/// a build that is writing into it stops the clean.
public struct OtherDerivedDataSource: CacheSource {
    public static let id = CategoryID("other-derived-data")
    public let displayName = "Other DerivedData"
    public let requiresLiveUseCheck = true
    /// ~/Library/Caches changes all the time for unrelated reasons.
    public let defersScheduledScanForRecentRootActivity = false

    private static let cachesRelativePath = "Library/Caches"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.cachesRelativePath)]
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.home.appending(path: Self.cachesRelativePath)
        guard TemporaryDerivedDataValidator.isRealDirectory(root) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return entries.compactMap { entry in
            let tool = entry.lastPathComponent
            // Apple's own cache folders belong to Xcode Caches.
            guard !tool.hasPrefix("com.apple."),
                TemporaryDerivedDataValidator.isRealDirectory(root.appending(path: tool))
            else { return nil }
            let derivedData = root.appending(path: tool).appending(path: "DerivedData")
            guard XcodeBuildFolderSignature.isDerivedDataRoot(derivedData) else { return nil }
            return CacheItem(
                categoryID: Self.id, url: derivedData, label: "\(tool) DerivedData")
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }
}

/// Xcode build-folder shape: a real `Build` directory plus one more Xcode
/// marker. A DerivedData root qualifies when it has the shape itself (one
/// `-derivedDataPath` build) or when one of its project folders has it.
enum XcodeBuildFolderSignature {
    private static let markers = [
        "Logs", "ModuleCache.noindex", "SourcePackages", "info.plist", "Index.noindex",
    ]

    static func isDerivedDataRoot(_ candidate: URL) -> Bool {
        guard TemporaryDerivedDataValidator.isRealDirectory(candidate) else { return false }
        if isBuildFolder(candidate) { return true }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return false }
        return children.contains { isBuildFolder(candidate.appending(path: $0.lastPathComponent)) }
    }

    static func isBuildFolder(_ candidate: URL) -> Bool {
        guard TemporaryDerivedDataValidator.isRealDirectory(candidate),
            TemporaryDerivedDataValidator.isRealDirectory(candidate.appending(path: "Build"))
        else { return false }
        return markers.contains { marker in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            guard let values = try? candidate.appending(path: marker).resourceValues(forKeys: keys),
                values.isSymbolicLink != true
            else { return false }
            return values.isDirectory == true || values.isRegularFile == true
        }
    }
}
