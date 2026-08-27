import Foundation

/// What a clean is about to do — feeds the confirmation dialog and the CLI's
/// dry-run output. Kept in CruftKit so the GUI stays thin and this logic is
/// unit-testable.
public struct CleanPlan: Sendable {
    public let itemsByCategory: [CategoryID: [CacheItem]]
    public let estimatedBytes: Int64
    /// Process warnings ("Xcode is running…") plus destructive-category
    /// warnings (Archives are NOT re-derivable).
    public let warnings: [String]

    public init(itemsByCategory: [CategoryID: [CacheItem]], estimatedBytes: Int64, warnings: [String]) {
        self.itemsByCategory = itemsByCategory
        self.estimatedBytes = estimatedBytes
        self.warnings = warnings
    }
}

/// Builds clean plans honoring Clean All membership rules:
/// a category is in Clean All iff the user explicitly included it, or it is
/// `includedInCleanAllByDefault` and not user-excluded. Destructive
/// categories are never in Clean All unless explicitly opted in. View-only
/// categories are never included.
public struct CleanPlanner: Sendable {
    /// Backward-compatible name for the Archives warning used by the app and
    /// existing callers. New destructive sources provide their own warning.
    public static let destructiveWarning = ArchivesSource.warning

    private let sources: [any CacheSource]

    public init(sources: [any CacheSource]) {
        self.sources = sources
    }

    public func planCleanAll(
        snapshots: [CategorySnapshot],
        userIncluded: Set<CategoryID> = [],
        userExcluded: Set<CategoryID> = [],
        processWarnings: [String] = []
    ) -> CleanPlan {
        var itemsByCategory: [CategoryID: [CacheItem]] = [:]
        var estimatedBytes: Int64 = 0
        var warnings = processWarnings
        for snapshot in snapshots {
            let id = snapshot.categoryID
            guard let source = source(for: id), !snapshot.items.isEmpty else { continue }
            guard source.supportsCleaning, source.allowsWholeCategoryCleaning else { continue }
            let included = userIncluded.contains(id)
                || (!source.isDestructive
                    && source.includedInCleanAllByDefault
                    && !userExcluded.contains(id))
            guard included else { continue }
            itemsByCategory[id] = snapshot.items.map(\.item)
            estimatedBytes += snapshot.totalBytes
            appendDestructiveWarning(for: source, to: &warnings)
        }
        return CleanPlan(
            itemsByCategory: itemsByCategory,
            estimatedBytes: estimatedBytes,
            warnings: warnings
        )
    }

    /// Plans one cleanable category regardless of Clean All membership flags.
    /// View-only categories always produce an empty plan. Destructive
    /// categories still carry their warning.
    public func planCategory(
        _ category: CategoryID,
        snapshots: [CategorySnapshot],
        processWarnings: [String] = []
    ) -> CleanPlan {
        var itemsByCategory: [CategoryID: [CacheItem]] = [:]
        var estimatedBytes: Int64 = 0
        var warnings = processWarnings
        if let source = source(for: category),
            source.supportsCleaning,
            source.allowsWholeCategoryCleaning,
            let snapshot = snapshots.first(where: { $0.categoryID == category }),
            !snapshot.items.isEmpty
        {
            itemsByCategory[category] = snapshot.items.map(\.item)
            estimatedBytes = snapshot.totalBytes
            appendDestructiveWarning(for: source, to: &warnings)
        }
        return CleanPlan(
            itemsByCategory: itemsByCategory,
            estimatedBytes: estimatedBytes,
            warnings: warnings
        )
    }

    /// Plans one explicit measured-item subset. This is the only planner path
    /// for sources that refuse broad category cleaning, such as simulators.
    /// Items that do not belong to the category or are not currently eligible
    /// are refused by omission.
    public func planSubset(
        _ category: CategoryID,
        measuredItems: [MeasuredItem],
        processWarnings: [String] = []
    ) -> CleanPlan {
        var warnings = processWarnings
        guard let source = source(for: category), source.supportsCleaning else {
            return CleanPlan(itemsByCategory: [:], estimatedBytes: 0, warnings: [])
        }
        let accepted = measuredItems.filter {
            $0.item.categoryID == category && source.canClean(measuredItem: $0)
        }
        guard !accepted.isEmpty else {
            return CleanPlan(itemsByCategory: [:], estimatedBytes: 0, warnings: [])
        }
        appendDestructiveWarning(for: source, to: &warnings)
        return CleanPlan(
            itemsByCategory: [category: accepted.map(\.item)],
            estimatedBytes: accepted.reduce(0) { $0 + ($1.size?.allocatedBytes ?? 0) },
            warnings: warnings)
    }

    private func appendDestructiveWarning(
        for source: any CacheSource, to warnings: inout [String]
    ) {
        if source.isDestructive, let warning = source.destructiveWarning {
            warnings.append(warning)
        }
    }

    private func source(for id: CategoryID) -> (any CacheSource)? {
        sources.first { $0.id == id }
    }
}
