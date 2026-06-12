import Foundation

/// `~/Library/Caches/org.swift.swiftpm` — SwiftPM's download/build cache,
/// one `.contentsOnly` item. Re-downloads on next resolve. The root itself
/// survives so SwiftPM never has to recreate it; its direct children
/// (repositories/, manifests/, …) are the deletion targets. Sibling
/// directories under `~/Library/Caches` belong to other apps and are never
/// touched.
public struct SwiftPMCacheSource: CacheSource {
    public static let id = CategoryID("swiftpm-cache")
    public let displayName = "Swift Package Manager Cache"

    private static let relativePath = "Library/Caches/org.swift.swiftpm"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.home.appending(path: Self.relativePath)]
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.home.appending(path: Self.relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        return [CacheItem(
            categoryID: Self.id, url: root, label: "SwiftPM cache", deletionMode: .contentsOnly)]
    }
}
