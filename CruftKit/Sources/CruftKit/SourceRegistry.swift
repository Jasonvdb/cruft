import Foundation

/// Single-owner file: ONLY the integrator edits this (a 7-way merge conflict
/// magnet otherwise). Order is display order in the menu and CLI output.
public enum SourceRegistry {
    public static var allSources: [any CacheSource] {
        allSources(agentWorktreePolicy: .strict)
    }

    /// The registry built around the user's worktree deletion policy. Only
    /// `AgentWorktreeSource` reads it; every other source is policy-free.
    public static func allSources(
        agentWorktreePolicy: AgentWorktreeDeletionPolicy
    ) -> [any CacheSource] {
        [
            DerivedDataSource(),
            TemporaryDerivedDataSource(),
            InRepoBuildSource(),
            AgentWorktreeSource(policy: agentWorktreePolicy),
            CargoSource(),
            GradleSource(),
            SwiftPMCacheSource(),
            XcodeMiscSource(),
            SimulatorDeviceDataSource(),
            XcodeBuildMCPSource(),
            JSCacheSource(),
            ArchivesSource(),
        ]
    }

    public static func source(for id: CategoryID) -> (any CacheSource)? {
        allSources.first { $0.id == id }
    }
}
