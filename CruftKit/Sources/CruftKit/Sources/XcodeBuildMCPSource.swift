import Foundation

/// `~/Library/Developer/XcodeBuildMCP/workspaces` — per-project build state
/// kept by the XcodeBuildMCP server (DerivedData, logs, result bundles,
/// state, locks; all re-derivable on the next MCP build). Items are the
/// per-project workspace subdirectories ("MockupCreator-6dbf557ddd52"), each
/// `.entireItem`; the workspaces directory itself always survives, and the
/// XcodeBuildMCP parent (which may hold configuration) is never targeted.
public struct XcodeBuildMCPSource: CacheSource {
    public static let id = CategoryID("xcodebuild-mcp")
    public let displayName = "XcodeBuildMCP Workspaces"

    public init() {}

    /// Every deletion for this category lives directly under the workspaces
    /// directory; XcodeBuildMCP-level siblings (config files, a `config`
    /// directory) are outside this root by construction, so SafeDeleter
    /// refuses them automatically.
    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [workspacesRoot(in: context)]
    }

    /// One item per direct child DIRECTORY of the workspaces root —
    /// per-project granularity ("MockupCreator-6dbf557ddd52"). Non-directory
    /// children (stray lock files) are not items, and symlinked children are
    /// excluded so an item can never point outside the root. A missing root
    /// means nothing to clean — not an error.
    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = workspacesRoot(in: context)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys))
        return children
            .filter { child in
                let values = try? child.resourceValues(forKeys: keys)
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .map { child in
                // contentsOfDirectory returns /private-prefixed,
                // trailing-slash URLs; rebuild on the canonical parent so
                // CacheItem.id never embeds a trailing slash (StatsStore and
                // CLI --exclude match on ids).
                CacheItem(
                    categoryID: Self.id,
                    url: root.appending(path: child.lastPathComponent),
                    label: child.lastPathComponent,
                    deletionMode: .entireItem
                )
            }
            .sorted { $0.label < $1.label }
    }

    private func workspacesRoot(in context: ScanContext) -> URL {
        context.home.appending(path: "Library/Developer/XcodeBuildMCP/workspaces")
    }
}
