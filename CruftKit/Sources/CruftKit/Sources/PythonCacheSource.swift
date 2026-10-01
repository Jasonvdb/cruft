import Foundation

/// Python package caches: uv (`~/.cache/uv`) and pip (`~/Library/Caches/pip`).
/// The roots survive and their contents are removed, as `uv cache clean` and
/// `pip cache purge` would do. `uvx` can run tools straight from the uv
/// cache, so a live-use check runs before deletion.
public struct PythonCacheSource: CacheSource {
    public static let id = CategoryID("python-cache")
    public let displayName = "Python Package Caches"
    public let requiresLiveUseCheck = true

    private static let cacheRoots: [(relativePath: String, label: String)] = [
        (".cache/uv", "uv cache"),
        ("Library/Caches/pip", "pip cache"),
    ]

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        Self.cacheRoots.map { context.home.appending(path: $0.relativePath) }
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        Self.cacheRoots.compactMap { candidate in
            let url = context.home.appending(path: candidate.relativePath)
            guard TemporaryDerivedDataValidator.isRealDirectory(url) else { return nil }
            return CacheItem(
                categoryID: Self.id, url: url, label: candidate.label, deletionMode: .contentsOnly)
        }
    }
}
