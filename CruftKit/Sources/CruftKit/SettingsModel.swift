import Foundation

/// Pure settings logic — interval clamping and the Clean All
/// include/exclude set algebra — kept in CruftKit so it is unit-testable
/// without the app target. The app's `SettingsStore` is the thin
/// UserDefaults binding around this value; nothing here touches disk.
///
/// Invariants:
/// - `cleanAllIncluded` and `cleanAllExcluded` are always disjoint. On
///   conflicting input (init/decode), exclusion wins — the safe direction
///   is "not in Clean All".
/// - `rescanIntervalHours` is always within `rescanIntervalRange`;
///   non-finite input falls back to the default.
public struct SettingsModel: Sendable, Equatable, Codable {
    public static let rescanIntervalRange: ClosedRange<Double> = 1...24
    public static let defaultRescanIntervalHours: Double = 4

    /// One category's Clean All membership as the user expressed it.
    /// `.standard` means "no override": the source's
    /// `includedInCleanAllByDefault`/`isDestructive` defaults apply.
    public enum CleanAllMembership: Sendable, Equatable {
        case included
        case excluded
        case standard
    }

    /// nil = the default `<home>/Documents/Repositories` (ScanContext's rule).
    public var projectsRootPath: String?
    /// Category raw values explicitly opted IN to Clean All — the only way
    /// a destructive category (Archives) ever joins it.
    public private(set) var cleanAllIncluded: Set<String>
    /// Default-in categories the user opted OUT of Clean All.
    public private(set) var cleanAllExcluded: Set<String>
    public var launchAtLogin: Bool
    public private(set) var rescanIntervalHours: Double

    public init(
        projectsRootPath: String? = nil,
        cleanAllIncluded: Set<String> = [],
        cleanAllExcluded: Set<String> = [],
        launchAtLogin: Bool = false,
        rescanIntervalHours: Double = SettingsModel.defaultRescanIntervalHours
    ) {
        self.projectsRootPath = projectsRootPath
        self.cleanAllExcluded = cleanAllExcluded
        self.cleanAllIncluded = cleanAllIncluded.subtracting(cleanAllExcluded)
        self.launchAtLogin = launchAtLogin
        self.rescanIntervalHours = Self.clampedInterval(rescanIntervalHours)
    }

    /// Decoding re-establishes the invariants the same way init does, so a
    /// hand-edited or stale defaults domain can never smuggle in an
    /// out-of-range interval or overlapping sets.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectsRootPath: try container.decodeIfPresent(String.self, forKey: .projectsRootPath),
            cleanAllIncluded: try container.decodeIfPresent(Set<String>.self, forKey: .cleanAllIncluded) ?? [],
            cleanAllExcluded: try container.decodeIfPresent(Set<String>.self, forKey: .cleanAllExcluded) ?? [],
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            rescanIntervalHours: try container.decodeIfPresent(Double.self, forKey: .rescanIntervalHours)
                ?? Self.defaultRescanIntervalHours
        )
    }

    // MARK: - Clean All membership

    public var cleanAllIncludedIDs: Set<CategoryID> {
        Set(cleanAllIncluded.map { CategoryID($0) })
    }

    public var cleanAllExcludedIDs: Set<CategoryID> {
        Set(cleanAllExcluded.map { CategoryID($0) })
    }

    public func membership(of id: CategoryID) -> CleanAllMembership {
        if cleanAllIncluded.contains(id.rawValue) { return .included }
        if cleanAllExcluded.contains(id.rawValue) { return .excluded }
        return .standard
    }

    /// The single mutation path for both sets — keeps them disjoint by
    /// construction.
    public mutating func setMembership(_ membership: CleanAllMembership, for id: CategoryID) {
        cleanAllIncluded.remove(id.rawValue)
        cleanAllExcluded.remove(id.rawValue)
        switch membership {
        case .included: cleanAllIncluded.insert(id.rawValue)
        case .excluded: cleanAllExcluded.insert(id.rawValue)
        case .standard: break
        }
    }

    /// Effective Clean All membership for one category, mirroring
    /// `CleanPlanner`'s rule exactly: explicit include wins; otherwise the
    /// category must be non-destructive, default-in, and not user-excluded.
    public func isInCleanAll(
        id: CategoryID, isDestructive: Bool, includedInCleanAllByDefault: Bool
    ) -> Bool {
        cleanAllIncluded.contains(id.rawValue)
            || (!isDestructive
                && includedInCleanAllByDefault
                && !cleanAllExcluded.contains(id.rawValue))
    }

    // MARK: - Rescan interval

    public mutating func setRescanIntervalHours(_ hours: Double) {
        rescanIntervalHours = Self.clampedInterval(hours)
    }

    private static func clampedInterval(_ hours: Double) -> Double {
        guard hours.isFinite else { return defaultRescanIntervalHours }
        return min(max(hours, rescanIntervalRange.lowerBound), rescanIntervalRange.upperBound)
    }
}
