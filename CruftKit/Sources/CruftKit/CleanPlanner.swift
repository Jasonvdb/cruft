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
    /// Warning attached to every destructive category in a plan. v1's only
    /// destructive source is Archives; text frozen by the Phase 3 spec.
    /// Public so the CLI prints the same words as the GUI dialog.
    public static let destructiveWarning = "Archives contain release dSYMs and CANNOT be re-derived."

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
            guard source.supportsCleaning else { continue }
            let included = userIncluded.contains(id)
                || (!source.isDestructive
                    && source.includedInCleanAllByDefault
                    && !userExcluded.contains(id))
            guard included else { continue }
            itemsByCategory[id] = snapshot.items.map(\.item)
            estimatedBytes += snapshot.totalBytes
            if source.isDestructive {
                warnings.append(Self.destructiveWarning)
            }
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
        if source(for: category)?.supportsCleaning == true,
            let snapshot = snapshots.first(where: { $0.categoryID == category }),
            !snapshot.items.isEmpty
        {
            itemsByCategory[category] = snapshot.items.map(\.item)
            estimatedBytes = snapshot.totalBytes
            if source(for: category)?.isDestructive == true {
                warnings.append(Self.destructiveWarning)
            }
        }
        return CleanPlan(
            itemsByCategory: itemsByCategory,
            estimatedBytes: estimatedBytes,
            warnings: warnings
        )
    }

    private func source(for id: CategoryID) -> (any CacheSource)? {
        sources.first { $0.id == id }
    }
}
