import Foundation

/// Miscellaneous Xcode caches: `~/Library/Caches/com.apple.dt.Xcode` and
/// `~/Library/Developer/CoreSimulator/Caches` — Caches ONLY, never
/// CoreSimulator/Devices (simulator data is not re-derivable and is
/// additionally protected by SafeDeleter's "Devices" denylist component).
public struct XcodeMiscSource: CacheSource {
    public static let id = CategoryID("xcode-misc")
    public let displayName = "Xcode Caches"

    /// Static cache roots relative to home, each surfaced as one
    /// `.contentsOnly` item: the directories themselves survive and
    /// Xcode/CoreSimulator repopulate them lazily.
    private static let cacheRoots: [(relativePath: String, label: String)] = [
        ("Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
    ]

    public init() {}

    /// Exactly the two cache roots — deliberately NOT
    /// `CoreSimulator` itself, so `CoreSimulator/Devices` (user data) can
    /// never validate against this source's roots.
    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        Self.cacheRoots.map { context.home.appending(path: $0.relativePath) }
    }

    /// Existence checks only — no listing, no sizing. A root that is
    /// missing (or a stray non-directory) is silently skipped, never an
    /// error.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        Self.cacheRoots.compactMap { candidate in
            let url = context.home.appending(path: candidate.relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return CacheItem(
                categoryID: Self.id, url: url, label: candidate.label, deletionMode: .contentsOnly)
        }
    }
}
