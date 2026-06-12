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
/// categories are never in Clean All unless explicitly opted in.
public struct CleanPlanner: Sendable {
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
        fatalError("CleanPlanner.planCleanAll not implemented (Phase 3)")
    }

    public func planCategory(
        _ category: CategoryID,
        snapshots: [CategorySnapshot],
        processWarnings: [String] = []
    ) -> CleanPlan {
        fatalError("CleanPlanner.planCategory not implemented (Phase 3)")
    }
}
