import Foundation

/// JavaScript package-manager caches: `~/.npm/_cacache`,
/// `~/Library/Caches/Yarn`, `~/Library/Caches/pnpm`, `~/Library/pnpm/store`.
/// All `.contentsOnly`; everything re-downloads on the next install.
///
/// Static known paths only in v1 (never shells out to `pnpm store path`).
/// Note: pnpm's store is clonefile-based on APFS, so reported sizes may
/// overlap with installed node_modules — freed bytes are reported from the
/// statfs delta, which is ground truth.
public struct JSCacheSource: CacheSource {
    public static let id = CategoryID("js-cache")
    public let displayName = "JS Package Caches"

    /// Static cache roots relative to home, each surfaced as one
    /// `.contentsOnly` item. Deliberately narrow: `~/.npm/_cacache` (never
    /// `~/.npm` itself — `_logs` etc. live there) and `~/Library/pnpm/store`
    /// (never `~/Library/pnpm` — `global` holds installed packages).
    private static let cacheRoots: [(relativePath: String, label: String)] = [
        (".npm/_cacache", "npm cache"),
        ("Library/Caches/Yarn", "Yarn cache"),
        ("Library/Caches/pnpm", "pnpm cache"),
        ("Library/pnpm/store", "pnpm store"),
    ]

    public init() {}

    /// Exactly the four cache roots.
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
