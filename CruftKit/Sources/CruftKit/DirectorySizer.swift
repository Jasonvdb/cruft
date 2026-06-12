import Foundation

/// The ONLY traversal abstraction. Sizing is a pure metadata walk — no file
/// contents are ever read. Swapping in a faster walker later (a raw
/// getattrlistbulk(2) implementation) touches exactly one conformance.
public protocol DirectoryMeasurer: Sendable {
    /// Walks `root` and returns its allocated size.
    ///
    /// Requirements (frozen):
    /// - Never follows symlinks; a symlinked directory contributes ~0 bytes.
    /// - Never reads file data; allocated bytes come from prefetched
    ///   `totalFileAllocatedSizeKey` (fallback `fileAllocatedSizeKey`).
    /// - Cooperative: checks `Task` cancellation and yields between chunks
    ///   (≤ 512 entries drained synchronously inside an autoreleasepool).
    /// - `partial` is invoked with throttled running totals (≤ 4 Hz).
    /// - Per-entry errors (ENOENT/EACCES) are counted in
    ///   `ItemSize.erroredEntries` and enumeration continues. A root-level
    ///   failure — root missing, volume gone, or root fsid/inode changed
    ///   since the walk started — throws instead; callers must discard the
    ///   partial result and keep the previous persisted snapshot.
    func measure(
        _ root: URL,
        partial: @Sendable (ItemSize) -> Void
    ) async throws -> ItemSize
}

/// v1 walker built on `FileManager.enumerator(at:includingPropertiesForKeys:)`
/// (the URL-based enumerator bulk-prefetches attributes via getattrlistbulk
/// internally — never use the path-based variant, which does not).
public struct FoundationMeasurer: DirectoryMeasurer {
    public init() {}

    public func measure(
        _ root: URL,
        partial: @Sendable (ItemSize) -> Void
    ) async throws -> ItemSize {
        fatalError("FoundationMeasurer not implemented (Phase 1)")
    }
}
