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

/// Root-level measurement failure. Per the `DirectoryMeasurer` contract,
/// callers discard any partial totals and keep the previous persisted
/// snapshot when one of these is thrown.
public enum MeasurementError: Error, Sendable, Equatable {
    /// The root did not exist when the walk started (or had vanished
    /// entirely by the time it finished).
    case rootMissing(URL)
    /// The root's (device, inode) identity changed between walk start and
    /// end — the tree was deleted or replaced underneath the walk, so the
    /// totals describe a mixture of two different trees.
    case rootReplaced(URL)
}

/// v1 walker built on `FileManager.enumerator(at:includingPropertiesForKeys:)`
/// (the URL-based enumerator bulk-prefetches attributes via getattrlistbulk
/// internally — never use the path-based variant, which does not).
public struct FoundationMeasurer: DirectoryMeasurer {
    /// Entries drained synchronously per autoreleasepool chunk.
    private static let chunkSize = 512

    /// Minimum spacing between `partial` emissions (≤ 4 Hz by contract).
    private let partialInterval: Duration

    public init() {
        self.partialInterval = .milliseconds(250)
    }

    /// Test hook: a tiny interval makes partial emissions deterministic
    /// without having to plant a tree that takes ≥ 250 ms to walk.
    init(partialInterval: Duration) {
        self.partialInterval = partialInterval
    }

    public func measure(
        _ root: URL,
        partial: @Sendable (ItemSize) -> Void
    ) async throws -> ItemSize {
        guard let rootIdentity = FileIdentity(of: root) else {
            throw MeasurementError.rootMissing(root)
        }

        // No .skipsHiddenFiles and no .skipsPackageDescendants: we must size
        // ModuleCache.noindex and the insides of bundles. Symlinks are not
        // followed by the enumerator by default.
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        let errors = ErrorTally()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                errors.value += 1
                return true
            }
        ) else {
            throw MeasurementError.rootMissing(root)
        }

        let clock = ContinuousClock()
        var lastEmission = clock.now
        var running = ItemSize()
        if let rootValues = try? root.resourceValues(forKeys: [.contentModificationDateKey]) {
            running.newestModificationDate = rootValues.contentModificationDate
        }

        while true {
            let drained = autoreleasepool {
                var count = 0
                while count < Self.chunkSize, let entry = enumerator.nextObject() as? URL {
                    count += 1
                    guard let values = try? entry.resourceValues(forKeys: keys) else {
                        errors.value += 1
                        continue
                    }
                    // A symlink entry contributes 0 bytes — its target is
                    // never followed, so a symlinked directory tree is never
                    // counted.
                    if values.isSymbolicLink == true { continue }
                    if let modified = values.contentModificationDate,
                        running.newestModificationDate.map({ modified > $0 }) ?? true
                    {
                        running.newestModificationDate = modified
                    }
                    guard values.isRegularFile == true else { continue }
                    running.fileCount += 1
                    running.allocatedBytes += Int64(
                        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
                return count
            }
            if drained < Self.chunkSize { break }

            try Task.checkCancellation()
            await Task.yield()

            let now = clock.now
            if now - lastEmission >= partialInterval {
                running.erroredEntries = errors.value
                partial(running)
                lastEmission = now
            }
        }

        running.erroredEntries = errors.value
        guard let endIdentity = FileIdentity(of: root) else {
            throw MeasurementError.rootMissing(root)
        }
        guard endIdentity == rootIdentity else {
            throw MeasurementError.rootReplaced(root)
        }
        return running
    }
}

/// (st_dev, st_ino) pair used to detect the root being deleted or replaced
/// while a walk was running.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(of url: URL) {
        var status = stat()
        guard stat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        self.device = status.st_dev
        self.inode = status.st_ino
    }
}

/// Per-entry error counter shared with the enumerator's `errorHandler`. The
/// handler runs serially, never concurrently — it only fires inside
/// `nextObject()`, which is only called from the single drain loop — so
/// plain mutation is safe; `@unchecked Sendable` only satisfies the
/// escaping-capture check.
private final class ErrorTally: @unchecked Sendable {
    var value = 0
}
