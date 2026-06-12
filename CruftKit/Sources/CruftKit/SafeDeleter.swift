import Foundation

/// Why SafeDeleter refused a deletion. Each case maps to one safety rule so
/// tests can assert the exact rule that fired.
public enum SafeDeleterError: Error, Equatable {
    /// Rule 2: the effective home is neither the real canonical $HOME nor a
    /// fixture location under a system temp area (`systemTempAreaPrefixes`).
    case homeOverrideRefused(String)
    /// Rule 1: resolved path escapes the canonical effective home.
    case outsideHome(String)
    /// Rule 3: resolved path is not inside any allowed deletion root.
    case outsideAllowedRoots(String)
    /// Rule 3: the path IS an allowed root and the item is `.entireItem`.
    case rootItselfRefused(String)
    /// Rule 4: a denylisted component appeared in the resolved path.
    case denylistedComponent(String, component: String)
    /// Rule 5: resolved path is fewer than 3 components below home.
    case depthFloorViolated(String)
    /// Rule 7: path does not exist.
    case doesNotExist(String)
    /// Rule 7: not owned by the current user.
    case notOwnedByCurrentUser(String)
}

/// THE deletion choke point. The only file in the repository where
/// file-removal APIs may appear (enforced by Scripts/check-chokepoint.sh in
/// every phase gate and in CI).
///
/// All rules compare canonical paths (`URL.cruftCanonical`) on both sides —
/// never mix canonicalization APIs; see the helper's doc. Denylist wins over
/// allowlist. `.dryRun` runs every check and records the deletion intent
/// without touching the disk.
public actor SafeDeleter: ItemDeleting {
    public enum Mode: Sendable, Equatable {
        case live
        case dryRun
    }

    /// Path components that are never deletable regardless of allowlist.
    /// "Mobile Documents" is iCloud Drive's backing store.
    public static let denylistedComponents: Set<String> = [
        ".git", "Devices", "DeviceSupport", "iOS DeviceSupport",
        "watchOS DeviceSupport", ".avd", "UserData", "Mobile Documents",
    ]

    public let mode: Mode
    /// Every URL deleted (live) or validated-as-deletable (dryRun), in order.
    public private(set) var deletedURLs: [URL] = []

    /// - Parameter home: canonical effective home (from `ScanContext.home`).
    ///   Throws `homeOverrideRefused` unless it is the real canonical $HOME
    ///   or lives under a system temp area (fixtures).
    public init(home: URL, mode: Mode) throws {
        // Implemented in Phase 1 (agent 1A). Stub validates nothing yet.
        self.mode = mode
        _ = home
        throw SafeDeleterError.homeOverrideRefused("SafeDeleter not implemented (Phase 1)")
    }

    @discardableResult
    public func delete(_ request: DeletionRequest) async throws -> [URL] {
        fatalError("SafeDeleter.delete not implemented (Phase 1)")
    }
}
