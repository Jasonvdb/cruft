import Foundation

/// `~/Library/Developer/Xcode/Archives` — DESTRUCTIVE: archives contain
/// release dSYMs needed for crash symbolication and are NOT re-derivable.
/// Never in Clean All by default; per-category clean shows a strong warning.
public struct ArchivesSource: CacheSource {
    public static let id = CategoryID("xcode-archives")
    public let displayName = "Xcode Archives"
    public let includedInCleanAllByDefault = false
    public let isDestructive = true

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("ArchivesSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("ArchivesSource not implemented (Phase 2)")
    }
}
