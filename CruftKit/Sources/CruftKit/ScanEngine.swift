import Foundation

/// Result of a clean operation. `freedBytes` is ground truth from a statfs
/// free-space delta on the volume (immune to APFS clones/hard links lying
/// about per-file allocation).
public struct CleanOutcome: Sendable, Codable {
    public let deletedPaths: [String]
    public let freedBytes: Int64

    public init(deletedPaths: [String], freedBytes: Int64) {
        self.deletedPaths = deletedPaths
        self.freedBytes = freedBytes
    }
}

/// Orchestrates discovery, sizing, and cleaning. Key invariants (frozen):
///
/// - Per-category UNSTRUCTURED `Task(priority:)` handles in an in-flight map;
///   width (`ScanTrigger.width`) is enforced inside the actor with a FIFO
///   queue. Dedup-by-awaiting an in-flight handle is what gives priority
///   escalation when a `.utility` trigger joins a `.background` scan.
/// - Per-category generations (never one global counter): a settings change
///   invalidates only affected categories.
/// - Per-category state machine idle/scanning/cleaning: `clean` cancels that
///   category's scan, bumps its generation, deletes, then starts a fresh
///   `.postClean` re-size. `.postClean` never dedups against a pre-clean task.
/// - `events` stream + continuation are created in `init`, so events emitted
///   before the consumer attaches buffer instead of vanishing. Single consumer.
/// - Quiet gate: roots (and DerivedData children) modified within ~3 minutes
///   defer scheduled scans and badge menu-open refreshes instead of scanning
///   mid-build.
/// - Watchdog: a category with no walker progress for 15 s emits `.failed`
///   and its task is abandoned (a blocked syscall on a dead mount cannot be
///   cancelled; we stop waiting on it instead).
/// - Non-local volumes are not sized; iCloud-ubiquitous roots are excluded.
public actor ScanEngine {
    public nonisolated let events: AsyncStream<ScanEvent>
    private let eventContinuation: AsyncStream<ScanEvent>.Continuation

    private let sources: [any CacheSource]
    private let context: ScanContext
    private let measurer: any DirectoryMeasurer
    private let deleter: any ItemDeleting

    public init(
        sources: [any CacheSource],
        context: ScanContext,
        measurer: any DirectoryMeasurer = FoundationMeasurer(),
        deleter: any ItemDeleting
    ) {
        (self.events, self.eventContinuation) = AsyncStream.makeStream(
            of: ScanEvent.self,
            bufferingPolicy: .unbounded
        )
        self.sources = sources
        self.context = context
        self.measurer = measurer
        self.deleter = deleter
    }

    /// Discover + size the given categories (nil = all registered, minus
    /// `context.excludedSourceIDs`). Dedups against in-flight scans except
    /// for `.postClean`, which always cancels-and-restarts.
    public func refresh(categories: Set<CategoryID>? = nil, trigger: ScanTrigger) async {
        fatalError("ScanEngine.refresh not implemented (Phase 3)")
    }

    /// Settings changed: cancel only the affected categories' tasks, bump
    /// their generations, rescan.
    public func invalidateAndRescan(categories: Set<CategoryID>) async {
        fatalError("ScanEngine.invalidateAndRescan not implemented (Phase 3)")
    }

    /// First-class clean: interlocked with scanning per the state machine.
    /// `items: nil` cleans every discovered item in the category.
    public func clean(category: CategoryID, items: [CacheItem]? = nil) async throws -> CleanOutcome {
        fatalError("ScanEngine.clean not implemented (Phase 3)")
    }

    public func cancelAll() {
        fatalError("ScanEngine.cancelAll not implemented (Phase 3)")
    }
}
