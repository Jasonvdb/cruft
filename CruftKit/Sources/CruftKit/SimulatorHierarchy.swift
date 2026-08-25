import Foundation

/// Pure grouping and sorting for the simulator hierarchy shown by the app.
/// CoreSimulator has no creator field, so only standard-name devices belong to
/// Xcode. Custom and unclassified devices belong to Other.
public struct SimulatorHierarchy: Sendable {
    public enum MainGroup: String, CaseIterable, Sendable, Hashable, Identifiable {
        case xcode
        case other

        public var id: Self { self }
        public var displayName: String {
            switch self {
            case .xcode: "Xcode"
            case .other: "Other"
            }
        }
    }

    public enum DeletionBlockReason: Sendable, Hashable, Identifiable {
        case booted
        case unknownMetadata
        case notReady

        public var id: Self { self }
    }

    public struct RuntimeGroup: Sendable, Identifiable {
        public let mainGroup: MainGroup
        public let runtimeLabel: String
        public let measuredItems: [MeasuredItem]
        public let allocatedBytes: Int64
        public let blockingReasons: [DeletionBlockReason]

        public var id: String { "\(mainGroup.rawValue):\(runtimeLabel)" }
        public var deviceCount: Int { measuredItems.count }
        public var isDeletable: Bool {
            !measuredItems.isEmpty && blockingReasons.isEmpty
        }

        fileprivate init(
            mainGroup: MainGroup,
            runtimeLabel: String,
            measuredItems: [MeasuredItem]
        ) {
            self.mainGroup = mainGroup
            self.runtimeLabel = runtimeLabel
            self.measuredItems = measuredItems
            self.allocatedBytes = measuredItems.reduce(0) {
                $0 + ($1.size?.allocatedBytes ?? 0)
            }

            var reasons: Set<DeletionBlockReason> = []
            for measured in measuredItems {
                guard let metadata = measured.item.simulatorMetadata else {
                    reasons.insert(.unknownMetadata)
                    continue
                }
                let metadataIsUnknown =
                    !metadata.hasKnownClassification || !metadata.hasExactIdentity
                if metadataIsUnknown {
                    reasons.insert(.unknownMetadata)
                }
                if metadata.isBooted {
                    reasons.insert(.booted)
                } else if !metadata.isEligibleForDeletion && !metadataIsUnknown {
                    reasons.insert(.notReady)
                }
            }
            let reasonOrder: [DeletionBlockReason] = [.booted, .unknownMetadata, .notReady]
            self.blockingReasons = reasonOrder.filter(reasons.contains)
        }
    }

    public struct Section: Sendable, Identifiable {
        public let mainGroup: MainGroup
        public let runtimeGroups: [RuntimeGroup]

        public var id: MainGroup { mainGroup }
        public var displayName: String { mainGroup.displayName }
    }

    /// Always emits exactly two sections, even while scanning or when one
    /// section has no devices. Old snapshots without metadata become
    /// Other / Unknown and cannot be deleted.
    public let sections: [Section]

    public init(snapshot: CategorySnapshot?) {
        var grouped: [GroupKey: [MeasuredItem]] = [:]
        for measured in snapshot?.items ?? [] {
            let metadata = measured.item.simulatorMetadata
            let mainGroup: MainGroup = metadata?.mainGroup == .xcode ? .xcode : .other
            let runtimeLabel: String
            if let label = metadata?.runtimeLabel, !label.isEmpty {
                runtimeLabel = label
            } else {
                runtimeLabel = "Unknown"
            }
            grouped[GroupKey(mainGroup: mainGroup, runtimeLabel: runtimeLabel), default: []]
                .append(measured)
        }

        self.sections = MainGroup.allCases.map { mainGroup in
            let runtimeGroups = grouped
                .filter { $0.key.mainGroup == mainGroup }
                .map { key, items in
                    RuntimeGroup(
                        mainGroup: mainGroup,
                        runtimeLabel: key.runtimeLabel,
                        measuredItems: items.sorted { $0.item.label < $1.item.label })
                }
                .sorted { Self.runtimeComesBefore($0.runtimeLabel, $1.runtimeLabel) }
            return Section(mainGroup: mainGroup, runtimeGroups: runtimeGroups)
        }
    }

    /// Returns the measured simulator snapshot that remains after exact paths
    /// were confirmed deleted. Untouched measurements and metadata stay in the
    /// snapshot so their runtime groups remain visible during the post-clean
    /// validation scan.
    public static func remainingSnapshot(
        from snapshot: CategorySnapshot,
        deletingPaths: [String]
    ) -> CategorySnapshot {
        let deleted = Set(deletingPaths.map(normalizedPath))
        var remaining = snapshot
        remaining.items.removeAll { measured in
            deleted.contains(normalizedPath(
                measured.item.url.path(percentEncoded: false)))
        }
        return remaining
    }

    private struct GroupKey: Hashable {
        let mainGroup: MainGroup
        let runtimeLabel: String
    }

    private struct RuntimeSortKey {
        let platformRank: Int
        let platform: String
        let version: [Int]?

        init(_ label: String) {
            let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
            self.platform = parts.first ?? label
            switch platform {
            case "iOS": platformRank = 0
            case "watchOS": platformRank = 1
            case "tvOS": platformRank = 2
            case "visionOS": platformRank = 3
            default: platformRank = 4
            }
            if parts.count == 2 {
                let versionParts = parts[1].split(separator: ".")
                let parsed = versionParts.compactMap { Int($0) }
                self.version = parsed.count == versionParts.count ? parsed : nil
            } else {
                self.version = nil
            }
        }
    }

    private static func runtimeComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = RuntimeSortKey(lhs)
        let right = RuntimeSortKey(rhs)
        if left.platformRank != right.platformRank {
            return left.platformRank < right.platformRank
        }
        if left.platform != right.platform {
            return left.platform < right.platform
        }
        switch (left.version, right.version) {
        case let (.some(leftVersion), .some(rightVersion)):
            let count = max(leftVersion.count, rightVersion.count)
            for index in 0..<count {
                let leftPart = index < leftVersion.count ? leftVersion[index] : 0
                let rightPart = index < rightVersion.count ? rightVersion[index] : 0
                if leftPart != rightPart { return leftPart > rightPart }
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhs < rhs
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
