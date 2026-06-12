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

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("JSCacheSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("JSCacheSource not implemented (Phase 2)")
    }
}
