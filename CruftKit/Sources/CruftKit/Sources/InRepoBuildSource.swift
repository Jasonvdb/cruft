import Foundation

/// Build outputs inside the user's projects root (default
/// `~/Documents/Repositories`): walks at most 4 directory levels below the
/// root looking for project markers (`*.xcodeproj`, `*.xcworkspace`,
/// `Package.swift`, `build.gradle(.kts)`, `settings.gradle(.kts)`), then
/// reports each project's direct `build/`, `.build/`, `.gradle/` children as
/// `.entireItem` items. Labels carry parent context (`ChessClock/build`)
/// because identity-by-label is impossible — six repos on the reference
/// machine have an item literally named "build".
///
/// Traversal rules:
/// - never descends into hidden (dot-prefixed) directories; `.build` and
///   `.gradle` are only CHECKED as item candidates, never entered
/// - never descends into `node_modules` or bundle-like directories
///   (`*.xcodeproj`, `*.xcworkspace`, `*.app`, …)
/// - never descends into a directory it just reported as an item
/// - never follows symlinked directories (`isSymbolicLinkKey`)
/// - nested projects are real: `android/` (build.gradle) and `android/app/`
///   (build.gradle) are both projects, so `android/app/build` is found via
///   `app` being a project one level deeper
///
/// Discovery is sizing-free and shallow: one `contentsOfDirectory` listing
/// per visited directory, no deep enumeration. A missing projects root
/// yields `[]`; a root-level listing failure (e.g. permission denied)
/// throws; unreadable or vanished nested directories are skipped so one bad
/// subtree cannot fail the category. Non-local and iCloud-ubiquitous roots
/// are the engine's concern; this source only reports what it can list.
public struct InRepoBuildSource: CacheSource {
    public static let id = CategoryID("in-repo-build")
    public let displayName = "Project Build Folders"

    /// A directory is a PROJECT if it directly contains one of these names…
    private static let markerNames: Set<String> = [
        "Package.swift",
        "build.gradle", "build.gradle.kts",
        "settings.gradle", "settings.gradle.kts",
    ]
    /// …or any entry with one of these bundle suffixes.
    private static let markerSuffixes = [".xcodeproj", ".xcworkspace"]

    /// Direct children of a project reported as cleanable items.
    private static let buildDirNames: Set<String> = ["build", ".build", ".gradle"]

    /// Bundle-like directories that are never entered (their contents are
    /// part of the bundle, not independent projects).
    private static let bundleSuffixes = [
        ".xcodeproj", ".xcworkspace", ".app", ".framework",
        ".bundle", ".xcassets", ".playground",
    ]

    /// Deepest directory level (relative to the projects root, which is
    /// level 0) that is visited and checked as a project candidate.
    private static let maxDepth = 4

    public init() {}

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [context.projectsRoot]
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = context.projectsRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }

        var items: [CacheItem] = []
        try walk(directory: root, depth: 0, into: &items)
        return items.sorted {
            $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false)
        }
    }

    /// One directory entry from a single shallow listing. Resource values
    /// describe the entry itself: a symlink to a directory is a symlink, not
    /// a directory we may enter.
    private struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
    }

    private func list(_ directory: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).map { listed in
            let values = try? listed.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values?.isSymbolicLink ?? false
            let name = listed.lastPathComponent
            // contentsOfDirectory returns the /private-prefixed spelling;
            // rebuild children on the canonical parent so item paths stay in
            // cruftCanonical form (the form SafeDeleter compares against).
            return Entry(
                url: directory.appending(path: name),
                name: name,
                isDirectory: !isSymlink && (values?.isDirectory ?? false),
                isSymlink: isSymlink
            )
        }
    }

    /// Marker kind matters: file markers (Package.swift, build.gradle) must
    /// not be directories, bundle markers (*.xcodeproj) must be — otherwise
    /// a stray directory named "build.gradle" would mark its parent a
    /// project and expose a sibling "build/" that isn't build output.
    private func isProject(_ entries: [Entry]) -> Bool {
        entries.contains { entry in
            (Self.markerNames.contains(entry.name) && !entry.isDirectory)
                || (Self.markerSuffixes.contains(where: entry.name.hasSuffix) && entry.isDirectory)
        }
    }

    private func walk(directory: URL, depth: Int, into items: inout [CacheItem]) throws {
        try Task.checkCancellation()
        let entries: [Entry]
        do {
            entries = try list(directory)
        } catch {
            // The root must be listable; nested failures (vanished mid-walk,
            // permission-denied subtree) skip that subtree and continue.
            if depth == 0 { throw error }
            return
        }

        var reportedNames: Set<String> = []
        if isProject(entries) {
            let projectName = directory.lastPathComponent
            for entry in entries
            where Self.buildDirNames.contains(entry.name) && entry.isDirectory {
                items.append(CacheItem(
                    categoryID: Self.id,
                    url: entry.url,
                    label: "\(projectName)/\(entry.name)",
                    deletionMode: .entireItem
                ))
                reportedNames.insert(entry.name)
            }
        }

        guard depth < Self.maxDepth else { return }
        for entry in entries where entry.isDirectory {
            if entry.name.hasPrefix(".") { continue }
            if entry.name == "node_modules" { continue }
            if Self.bundleSuffixes.contains(where: entry.name.hasSuffix) { continue }
            if reportedNames.contains(entry.name) { continue }
            try walk(directory: entry.url, depth: depth + 1, into: &items)
        }
    }
}
