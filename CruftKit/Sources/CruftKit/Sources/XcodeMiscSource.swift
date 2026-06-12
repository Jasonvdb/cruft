import Foundation

/// Miscellaneous Xcode caches: `~/Library/Caches/com.apple.dt.Xcode` and
/// `~/Library/Developer/CoreSimulator/Caches` — Caches ONLY, never
/// CoreSimulator/Devices (simulator data is not re-derivable and is
/// additionally protected by SafeDeleter's "Devices" denylist component).
public struct XcodeMiscSource: CacheSource {
    public static let id = CategoryID("xcode-misc")
    public let displayName = "Xcode Caches"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("XcodeMiscSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("XcodeMiscSource not implemented (Phase 2)")
    }
}
