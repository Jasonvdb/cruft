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

        public var id: String { measuredItem.item.id }
        public var label: String { measuredItem.item.label }
        public var url: URL { measuredItem.item.url }
        public var allocatedBytes: Int64 { measuredItem.size?.allocatedBytes ?? 0 }
        public var newestModificationDate: Date? {
            measuredItem.size?.newestModificationDate
        }
        public var isDeletable: Bool { blockingReasons.isEmpty }
    }

    public let rows: [Row]

    public init(snapshot: CategorySnapshot?, now: Date = Date()) {
        self.rows = (snapshot?.items ?? []).map { measured in
            Row(
                measuredItem: measured,
                blockingReasons: Self.blockingReasons(for: measured, now: now))
        }
        .sorted {
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false)
        }
    }

    public static func blockingReasons(
        for measured: MeasuredItem,
        now: Date = Date()
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
