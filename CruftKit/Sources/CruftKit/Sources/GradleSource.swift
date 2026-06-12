import Foundation

/// Gradle home caches: `~/.gradle/caches` and `~/.gradle/daemon`, each a
/// `.contentsOnly` item (the directories themselves survive; Gradle
/// recreates contents on the next build). In-repo `.gradle`/`app/build`
/// dirs belong to InRepoBuildSource.
///
/// `.contentsOnly` is load-bearing here, not just politeness: both roots sit
/// only 2 path components below home, under SafeDeleter's 3-component depth
/// floor. Deleting either root itself would be refused; their direct
/// children (3 components deep) are what actually validate and get deleted.
///
/// NOT in v1: `~/.gradle/wrapper` (downloaded Gradle distributions are
/// expensive to re-fetch) and loose files like `~/.gradle/gradle.properties`
/// (user configuration, not cache).
public struct GradleSource: CacheSource {
    public static let id = CategoryID("gradle")
    public let displayName = "Gradle Caches"

    /// Fixed roots scanned under `<home>/.gradle`, with display labels.
    private static let roots: [(relativePath: String, label: String)] = [
        (".gradle/caches", "Gradle caches"),
        (".gradle/daemon", "Gradle daemon logs"),
    ]

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        Self.roots.map { context.home.appending(path: $0.relativePath) }
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        Self.roots.compactMap { root in
            let url = context.home.appending(path: root.relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return CacheItem(
                categoryID: Self.id, url: url, label: root.label, deletionMode: .contentsOnly)
        }
    }
}
