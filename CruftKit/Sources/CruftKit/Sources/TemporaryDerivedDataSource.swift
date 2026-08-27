import Foundation

/// Xcode DerivedData directories created with `-derivedDataPath` directly
/// under /private/tmp. These are separate from Xcode's normal per-user
/// DerivedData root. Discovery requires both a DerivedData-like name and an
/// Xcode directory signature. Cleanup is explicit per item and age-gated.
public struct TemporaryDerivedDataSource: CacheSource {
    public static let id = CategoryID("temporary-derived-data")
    public let displayName = "Temporary DerivedData"
    public let includedInCleanAllByDefault = false
    public let allowsWholeCategoryCleaning = false
    public let defersScheduledScanForRecentRootActivity = false

    public init() {}

    public func scanRoot(context: ScanContext) -> URL? {
        Self.temporaryRoot(context: context)
    }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [Self.temporaryRoot(context: context)]
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id && item.deletionMode == .temporaryDerivedData
    }

    public func canClean(measuredItem: MeasuredItem) -> Bool {
        canClean(item: measuredItem.item)
            && GuardedCleanupPolicy.hasCompleteOldMeasurement(measuredItem.size)
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = Self.temporaryRoot(context: context)
        guard TemporaryDerivedDataValidator.isRealDirectory(root) else { return [] }

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return entries.compactMap { listed in
            let listedCandidate = root.appending(path: listed.lastPathComponent)
            guard TemporaryDerivedDataValidator.hasXcodeSignature(listedCandidate) else { return nil }
            // `/private/tmp` is the real directory, while cruftCanonical uses
            // `/tmp` for comparisons. Validate through the physical spelling,
            // then retain the canonical spelling on the item.
            let candidate = listedCandidate.cruftCanonical
            return CacheItem(
                categoryID: Self.id,
                url: candidate,
                label: candidate.lastPathComponent,
                deletionMode: .temporaryDerivedData)
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    /// Fixture runs must never inspect the Mac's shared /private/tmp. They use
    /// a private stand-in below the fixture home. Real-home runs use the one
    /// canonical spelling of /private/tmp (/tmp on macOS Foundation).
    static func temporaryRoot(context: ScanContext) -> URL {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.cruftCanonical
        if normalizedPath(context.home) == normalizedPath(realHome) {
            return URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        }
        return context.home.appending(path: "private-tmp")
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.cruftCanonical.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// One shared strict signature used at discovery and deletion time.
enum TemporaryDerivedDataValidator {
    private static let supportingMarkers = [
        "Logs", "ModuleCache.noindex", "SourcePackages", "info.plist",
    ]

    static func hasXcodeSignature(_ candidate: URL) -> Bool {
        let name = candidate.lastPathComponent.lowercased()
        guard name.contains("deriveddata"),
            isRealDirectory(candidate),
            isRealDirectory(candidate.appending(path: "Build"))
        else { return false }
        return supportingMarkers.contains { marker in
            let url = candidate.appending(path: marker)
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isSymbolicLink != true
            else { return false }
            return values.isDirectory == true || values.isRegularFile == true
        }
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
