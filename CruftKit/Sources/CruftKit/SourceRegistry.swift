import Foundation

/// Single-owner file: ONLY the integrator edits this (a 7-way merge conflict
/// magnet otherwise). Populated in Phase 3 once all sources are merged.
public enum SourceRegistry {
    public static var allSources: [any CacheSource] {
        []
    }
}
