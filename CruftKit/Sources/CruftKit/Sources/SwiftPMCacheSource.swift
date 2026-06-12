import Foundation

/// `~/Library/Caches/org.swift.swiftpm` — SwiftPM's download/build cache,
/// one `.contentsOnly` item. Re-downloads on next resolve.
public struct SwiftPMCacheSource: CacheSource {
    public static let id = CategoryID("swiftpm-cache")
    public let displayName = "Swift Package Manager Cache"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("SwiftPMCacheSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("SwiftPMCacheSource not implemented (Phase 2)")
    }
}
