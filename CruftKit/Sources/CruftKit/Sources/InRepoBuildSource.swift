import Foundation

/// Build outputs inside the user's projects root (default
/// `~/Documents/Repositories`): walks at most 4 levels deep looking for
/// project markers (`*.xcodeproj`, `Package.swift`, `build.gradle(.kts)`,
/// `settings.gradle(.kts)`), then reports sibling `build/`, `.build/`,
/// `.gradle/` and android `app/build` dirs as `.entireItem` items.
///
/// Never descends into hidden directories, `node_modules`, `.git`, or a
/// matched build directory. Non-local and iCloud-ubiquitous roots are the
/// engine's concern; this source only reports what it can list.
public struct InRepoBuildSource: CacheSource {
    public static let id = CategoryID("in-repo-build")
    public let displayName = "Project Build Folders"

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        fatalError("InRepoBuildSource not implemented (Phase 2)")
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        fatalError("InRepoBuildSource not implemented (Phase 2)")
    }
}
