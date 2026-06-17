import Foundation

/// Rust/Cargo build output (`target/`) inside the user's projects root
/// (default `~/Documents/Repositories`): walks at most 4 directory levels
/// below the root looking for Cargo packages/workspaces (a directory that
/// directly contains a `Cargo.toml` *file*), then reports each one's direct
/// `target/` child as an `.entireItem` item. Labels carry parent context
/// (`pkresolver/target`) because identity-by-label is impossible — `target`
/// is the only name Cargo ever uses, so every Rust project's item is named
/// "target".
///
/// Why a dedicated source rather than another entry in `InRepoBuildSource`:
/// `target/` is a *generic* directory name (Maven, and ad-hoc build scripts,
/// use it too), so it is only ever reported when a sibling `Cargo.toml`
/// file proves the parent is a Cargo project. Gating on that marker is what
/// keeps an unrelated `target/` safe; keeping the logic here leaves the
/// already-audited in-repo walk untouched.
///
/// Cargo only writes `target/` at the package or workspace root, so a
/// workspace's member crates (which have their own `Cargo.toml` but no
/// `target/`) naturally report nothing — the rule "a `target/` child must
/// sit next to a `Cargo.toml`" handles workspaces for free.
///
/// Traversal rules mirror `InRepoBuildSource` (the safety-critical ones are
/// shared by design):
/// - never descends into hidden (dot-prefixed) directories
/// - never descends into `node_modules` or bundle-like directories
///   (`*.xcodeproj`, `*.app`, …)
/// - never descends into a `target/` it just reported as an item
/// - never follows symlinked directories (`isSymbolicLinkKey`)
///
/// Discovery is sizing-free and shallow: one `contentsOfDirectory` listing
/// per visited directory. A missing projects root yields `[]`; a root-level
/// listing failure throws; unreadable or vanished nested directories are
/// skipped so one bad subtree cannot fail the category.
public struct CargoSource: CacheSource {
    public static let id = CategoryID("cargo-target")
    public let displayName = "Cargo Target Folders"

    /// A directory is a Cargo project if it directly contains this *file*.
    private static let markerName = "Cargo.toml"
    /// The single direct child reported as a cleanable item.
    private static let buildDirName = "target"

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

    /// Marker KIND matters: `Cargo.toml` must be a FILE. A stray *directory*
    /// named `Cargo.toml` next to a `target/` must not mark its parent a
    /// project and expose that `target/` for deletion.
    private func isCargoProject(_ entries: [Entry]) -> Bool {
        entries.contains { $0.name == Self.markerName && !$0.isDirectory }
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

        var reportedTarget = false
        if isCargoProject(entries),
           let target = entries.first(where: {
               $0.name == Self.buildDirName && $0.isDirectory
           }) {
            let projectName = directory.lastPathComponent
            items.append(CacheItem(
                categoryID: Self.id,
                url: target.url,
                label: "\(projectName)/\(Self.buildDirName)",
                deletionMode: .entireItem
            ))
            reportedTarget = true
        }

        guard depth < Self.maxDepth else { return }
        for entry in entries where entry.isDirectory {
            if entry.name.hasPrefix(".") { continue }
            if entry.name == "node_modules" { continue }
            if Self.bundleSuffixes.contains(where: entry.name.hasSuffix) { continue }
            // Never descend into a target/ we just reported, and never walk
            // INTO a target/ at all — nested crates under it share this root.
            if entry.name == Self.buildDirName && reportedTarget { continue }
            try walk(directory: entry.url, depth: depth + 1, into: &items)
        }
    }
}
