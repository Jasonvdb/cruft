import Foundation

/// Pure presentation reducer for the menu bar UI. Every display rule lives
/// here so the app target stays a thin rendering layer and the rules stay
/// testable without SwiftUI.
///
/// Presentation rule (frozen): a row with a prior FINAL value keeps showing
/// it (plus an activity indicator) during a rescan; `.partial` snapshots
/// drive the primary number only when no prior final exists (first launch or
/// post-clean). `.finished` swaps the number atomically. `.failed` and
/// `.deferred` keep the previous number and add a status. The total is
/// always the sum of the displayed row values, so it never dips mid-refresh.
public struct MenuState: Sendable {
    /// What a category row is doing right now, rendered as a spinner/badge
    /// next to the (possibly retained) number.
    public enum Activity: Sendable, Equatable {
        /// No scan in flight. `updatedAt` is when the displayed number was
        /// last confirmed by a `.finished` scan (nil = never scanned).
        case idle(updatedAt: Date?)
        case discovering
        case sizing
        case deferred(DeferralReason)
        case failed(String)
    }

    /// One menu row. `bytes` and `itemCount` are the DISPLAYED values —
    /// they follow the retention rule above, not the raw event stream.
    public struct Row: Identifiable, Sendable {
        public let id: CategoryID
        public let displayName: String
        public let isDestructive: Bool
        public internal(set) var bytes: Int64?
        public internal(set) var itemCount: Int?
        public internal(set) var activity: Activity
        /// True once a `.finished` (or persisted) snapshot backs the number;
        /// gates whether `.partial` events may drive the display.
        var hasFinalValue: Bool

        init(
            id: CategoryID,
            displayName: String,
            isDestructive: Bool,
            bytes: Int64? = nil,
            itemCount: Int? = nil,
            activity: Activity = .idle(updatedAt: nil),
            hasFinalValue: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.isDestructive = isDestructive
            self.bytes = bytes
            self.itemCount = itemCount
            self.activity = activity
            self.hasFinalValue = hasFinalValue
        }
    }

    /// Registry order — never resorted.
    public private(set) var rows: [Row]

    /// Sum of every displayed row value. Because displayed values are
    /// retained across rescans, this never dips mid-refresh.
    public var displayedTotalBytes: Int64 {
        rows.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// Rows in the order `sources` are given (registry order); persisted
    /// snapshots paint initial values so the first frame shows real numbers
    /// with their `updatedAt`.
    public init(sources: [any CacheSource], persisted: [CategorySnapshot]) {
        let persistedByID = Dictionary(
            persisted.map { ($0.categoryID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        rows = sources.map { source in
            if let snapshot = persistedByID[source.id] {
                Row(
                    id: source.id,
                    displayName: source.displayName,
                    isDestructive: source.isDestructive,
                    bytes: snapshot.totalBytes,
                    itemCount: snapshot.items.count,
                    activity: .idle(updatedAt: snapshot.updatedAt),
                    hasFinalValue: true
                )
            } else {
                Row(
                    id: source.id,
                    displayName: source.displayName,
                    isDestructive: source.isDestructive
                )
            }
        }
    }

    public mutating func apply(_ event: ScanEvent) {
        switch event {
        case .categoryStarted(let id):
            mutate(id) { $0.activity = .discovering }
        case .discovered(let id, let items):
            mutate(id) { row in
                row.activity = .sizing
                // Discovery yields the truthful item count immediately; the
                // displayed count only follows it when no final backs the row
                // (partial snapshots carry fewer items than discovery found).
                if !row.hasFinalValue {
                    row.itemCount = items.count
                }
            }
        case .partial(let id, let snapshot):
            mutate(id) { row in
                row.activity = .sizing
                if !row.hasFinalValue {
                    row.bytes = snapshot.totalBytes
                }
            }
        case .finished(let id, let snapshot):
            mutate(id) { row in
                row.bytes = snapshot.totalBytes
                row.itemCount = snapshot.items.count
                row.activity = .idle(updatedAt: snapshot.updatedAt)
                row.hasFinalValue = true
            }
        case .deferred(let id, let reason):
            mutate(id) { $0.activity = .deferred(reason) }
        case .failed(let id, let message):
            mutate(id) { $0.activity = .failed(message) }
        }
    }

    /// A clean just deleted this category's items: the retained final is no
    /// longer truthful, so drop it and let the `.postClean` rescan's partials
    /// drive the number from zero. (Phase 5 calls this when wiring cleans.)
    public mutating func noteCleaned(_ id: CategoryID) {
        mutate(id) { row in
            row.bytes = nil
            row.itemCount = nil
            row.hasFinalValue = false
        }
    }

    private mutating func mutate(_ id: CategoryID, _ body: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        body(&rows[index])
    }
}
