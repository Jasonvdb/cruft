import Foundation

/// Injectable process-query seam so ProcessGuard tests are hermetic (whether
/// Xcode is running differs between dev machines, verifier worktrees, and CI).
public protocol ProcessQuerying: Sendable {
    func runningAppBundleIDs() -> Set<String>
    func processCommandLines() -> [String]
}

/// Real implementation backed by NSWorkspace and `pgrep`.
public struct SystemProcessQuerier: ProcessQuerying {
    public init() {}

    public func runningAppBundleIDs() -> Set<String> {
        fatalError("SystemProcessQuerier not implemented (Phase 1)")
    }

    public func processCommandLines() -> [String] {
        fatalError("SystemProcessQuerier not implemented (Phase 1)")
    }
}

/// Warn-only in v1: detects tools that may be actively writing into a cache
/// category (Xcode for DerivedData/Xcode misc, Gradle daemons for Gradle).
/// Clean confirmations surface these warnings; nothing is blocked.
public struct ProcessGuard: Sendable {
    private let querier: any ProcessQuerying

    public init(querier: any ProcessQuerying = SystemProcessQuerier()) {
        self.querier = querier
    }

    /// Human-readable warnings for the categories about to be cleaned.
    public func warnings(for categories: Set<CategoryID>) -> [String] {
        fatalError("ProcessGuard not implemented (Phase 1)")
    }
}
