import Foundation

/// `~/Library/Developer/Xcode/DerivedData` — items are the per-project
/// subdirectories plus ModuleCache.noindex, each `.entireItem`; the
/// DerivedData directory itself always survives.
public struct DerivedDataSource: CacheSource {
    public static let id = CategoryID("derived-data")
    public let displayName = "Xcode DerivedData"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("DerivedDataSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("DerivedDataSource not implemented (Phase 2)")
    }
}
