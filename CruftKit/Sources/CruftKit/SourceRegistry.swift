import Foundation

/// Single-owner file: ONLY the integrator edits this (a 7-way merge conflict
/// magnet otherwise). Order is display order in the menu and CLI output.
public enum SourceRegistry {
    public static var allSources: [any CacheSource] {
        [
            DerivedDataSource(),
            InRepoBuildSource(),
            GradleSource(),
            SwiftPMCacheSource(),
            XcodeMiscSource(),
            JSCacheSource(),
            ArchivesSource(),
        ]
    }

    public static func source(for id: CategoryID) -> (any CacheSource)? {
        allSources.first { $0.id == id }
    }
}
