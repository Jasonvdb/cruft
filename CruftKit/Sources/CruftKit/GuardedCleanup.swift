import Foundation

/// Shared age rule for temporary DerivedData and agent worktrees. Age is one
/// required signal, never proof of inactivity by itself. SafeDeleter repeats
/// the age check and performs live open-file/process checks before deletion.
public enum GuardedCleanupPolicy {
    public static let minimumUntouchedInterval: TimeInterval = 3 * 24 * 60 * 60

    public static func hasCompleteOldMeasurement(
        _ size: ItemSize?,
        now: Date = Date()
    ) -> Bool {
        guard let size,
            size.erroredEntries == 0,
            let modified = size.newestModificationDate
        else { return false }
        return now.timeIntervalSince(modified) >= minimumUntouchedInterval
    }
}

/// Pure presentation model for the two explicit-item cleanup categories.
/// It explains why a row is blocked without claiming that age proves idle
/// use. The live active-use check happens only after user confirmation.
public struct GuardedCleanupList: Sendable {
    public enum BlockingReason: Sendable, Hashable, Identifiable {
        case recent
        case ageUnknown
        case measurementIncomplete
        case worktreeMetadataUnknown
        case dirty
        case locked
        case notContainedInPrimaryBranch

        public var id: Self { self }
    }

    public struct Row: Sendable, Identifiable {
        public let measuredItem: MeasuredItem
        public let blockingReasons: [BlockingReason]
        /// Reasons that WOULD block under the strict policy but the user has
        /// waived. The row stays deletable and keeps showing their badges —
        /// a waived reason is still a fact worth seeing before clicking.
        public let waivedReasons: [BlockingReason]

        public var id: String { measuredItem.item.id }
        public var label: String { measuredItem.item.label }
        public var url: URL { measuredItem.item.url }
        public var allocatedBytes: Int64 { measuredItem.size?.allocatedBytes ?? 0 }
        public var newestModificationDate: Date? {
            measuredItem.size?.newestModificationDate
        }
        public var isDeletable: Bool { blockingReasons.isEmpty }
        /// True when confirming this row destroys work that exists nowhere
        /// else. Unmerged commits survive (`git worktree remove` keeps the
        /// branch); uncommitted and untracked files do not.
        public var discardsUncommittedWork: Bool { waivedReasons.contains(.dirty) }
    }

    public let rows: [Row]

    public init(
        snapshot: CategorySnapshot?,
        policy: AgentWorktreeDeletionPolicy = .strict,
        now: Date = Date()
    ) {
        self.rows = (snapshot?.items ?? []).map { measured in
            let split = Self.reasons(for: measured, policy: policy, now: now)
            return Row(
                measuredItem: measured,
                blockingReasons: split.blocking,
                waivedReasons: split.waived)
        }
        .sorted {
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false)
        }
    }

    /// Strict blocking reasons — unchanged behaviour for callers that do not
    /// carry a policy.
    public static func blockingReasons(
        for measured: MeasuredItem,
        now: Date = Date()
    ) -> [BlockingReason] {
        reasons(for: measured, policy: .strict, now: now).blocking
    }

    /// Splits the strict reason set into what still blocks and what the
    /// policy waives. Only `.dirty` and `.notContainedInPrimaryBranch` are
    /// ever waivable; age, measurement, lock, and metadata refusals are not.
    public static func reasons(
        for measured: MeasuredItem,
        policy: AgentWorktreeDeletionPolicy,
        now: Date = Date()
    ) -> (blocking: [BlockingReason], waived: [BlockingReason]) {
        let all = Set(strictReasons(for: measured, now: now))
        guard policy.allowsDirtyOrUnmerged else {
            return (ordered(all), [])
        }
        let waivable: Set<BlockingReason> = [.dirty, .notContainedInPrimaryBranch]
        return (ordered(all.subtracting(waivable)), ordered(all.intersection(waivable)))
    }

    private static func strictReasons(
        for measured: MeasuredItem,
        now: Date
    ) -> [BlockingReason] {
        var reasons: Set<BlockingReason> = []
        if let size = measured.size {
            if size.erroredEntries > 0 {
                reasons.insert(.measurementIncomplete)
            }
            if let modified = size.newestModificationDate {
                if now.timeIntervalSince(modified) < GuardedCleanupPolicy.minimumUntouchedInterval {
                    reasons.insert(.recent)
                }
            } else {
                reasons.insert(.ageUnknown)
            }
        } else {
            reasons.insert(.ageUnknown)
        }

        if measured.item.deletionMode == .agentWorktree {
            guard let metadata = measured.item.agentWorktreeMetadata,
                metadata.isRegistered,
                !metadata.headRevision.isEmpty,
                metadata.primaryReference != nil
            else {
                reasons.insert(.worktreeMetadataUnknown)
                return Self.ordered(reasons)
            }
            if !metadata.isClean { reasons.insert(.dirty) }
            if metadata.isLocked { reasons.insert(.locked) }
            if !metadata.isContainedInPrimaryBranch {
                reasons.insert(.notContainedInPrimaryBranch)
            }
        }
        return Self.ordered(reasons)
    }

    private static func ordered(_ reasons: Set<BlockingReason>) -> [BlockingReason] {
        let order: [BlockingReason] = [
            .dirty, .locked, .notContainedInPrimaryBranch,
            .worktreeMetadataUnknown, .measurementIncomplete, .ageUnknown, .recent,
        ]
        return order.filter(reasons.contains)
    }
}
