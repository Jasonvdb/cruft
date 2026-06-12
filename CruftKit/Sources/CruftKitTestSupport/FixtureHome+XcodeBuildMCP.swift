import Foundation

/// XcodeBuildMCP fixture recipes, built strictly on the frozen FixtureHome
/// DSL primitives.
extension FixtureHome {
    /// Relative path of the XcodeBuildMCP workspaces root inside a fixture
    /// home.
    public static let xcodeBuildMCPWorkspacesPath = "Library/Developer/XcodeBuildMCP/workspaces"

    /// Plants the workspaces directory itself, empty.
    @discardableResult
    public func plantXcodeBuildMCPWorkspacesRoot() throws -> URL {
        try plantDir(Self.xcodeBuildMCPWorkspacesPath)
    }

    /// Plants one per-project workspace ("MockupCreator-6dbf557ddd52") with
    /// a realistic inner layout (DerivedData, logs, result bundles, state,
    /// locks — what the MCP server keeps per project).
    @discardableResult
    public func plantXcodeBuildMCPWorkspace(_ name: String) throws -> URL {
        let workspace = "\(Self.xcodeBuildMCPWorkspacesPath)/\(name)"
        try plantFile("\(workspace)/DerivedData/Build/Products/Debug/app.bin")
        try plantFile("\(workspace)/logs/build.log")
        try plantFile("\(workspace)/result-bundles/Test.xcresult/Info.plist")
        try plantFile("\(workspace)/state/session.json")
        try plantFile("\(workspace)/locks/build.lock")
        return url(workspace)
    }

    /// Plants a non-directory child at the workspaces root (e.g. a stray
    /// `.lock` file) that discovery must skip.
    @discardableResult
    public func plantXcodeBuildMCPWorkspacesRootFile(_ name: String) throws -> URL {
        try plantFile("\(Self.xcodeBuildMCPWorkspacesPath)/\(name)")
    }

    /// Plants the XcodeBuildMCP-level siblings of `workspaces/` that must
    /// NEVER be discovered or deleted: a config file and a `config`
    /// directory living directly under `Library/Developer/XcodeBuildMCP`
    /// (the parent may hold configuration; only workspaces/ children are
    /// cache). Returns the decoy paths (relative to the fixture root) for
    /// both-direction assertions.
    @discardableResult
    public func plantXcodeBuildMCPDecoys() throws -> [String] {
        let decoys = [
            "Library/Developer/XcodeBuildMCP/config.json",
            "Library/Developer/XcodeBuildMCP/config",
        ]
        try plantFile(decoys[0])
        try plantFile("\(decoys[1])/settings.json")
        return decoys
    }
}
