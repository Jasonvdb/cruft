import Foundation

/// Gradle home caches: `~/.gradle/caches` and `~/.gradle/daemon`, each a
/// `.contentsOnly` item (the directories themselves survive; Gradle
/// recreates contents on the next build). In-repo `.gradle`/`app/build`
/// dirs belong to InRepoBuildSource.
public struct GradleSource: CacheSource {
    public static let id = CategoryID("gradle")
    public let displayName = "Gradle Caches"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("GradleSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("GradleSource not implemented (Phase 2)")
    }
}
