import ArgumentParser
import CruftKit
import Foundation

// =============================================================================
// FROZEN CLI SURFACE (contracts v1): subcommand names, flags, and the scan
// JSON schema below are frozen in Phase 0 — gates in later phases script
// against them. Implementations land in Phase 3 (agent 3B).
//
// scan JSON schema:
// {
//   "categories": [
//     { "id": "derived-data", "displayName": "Xcode DerivedData",
//       "bytes": 123, "itemCount": 2,
//       "items": [ { "path": "/...", "label": "Foo", "bytes": 123, "fileCount": 4 } ] }
//   ]
// }
// =============================================================================

@main
struct CruftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cruft-cli",
        abstract: "Scan and clean re-derivable developer build caches.",
        subcommands: [Scan.self, Clean.self, Fixture.self]
    )
}

/// Context flags shared by scan and clean.
struct ContextOptions: ParsableArguments {
    @Option(name: .customLong("home"), help: ArgumentHelp(
        "Override the home directory (fixture testing). Also honored via the CRUFT_HOME environment variable. Refused by SafeDeleter unless it is the real home or under the system temp areas."))
    var home: String?

    @Option(name: .customLong("projects-root"), help: "Root scanned for in-repo build outputs (default: <home>/Documents/Repositories).")
    var projectsRoot: String?

    @Option(name: .customLong("exclude"), help: "Category id to exclude (repeatable).")
    var exclude: [String] = []

    func makeContext() -> ScanContext {
        let envHome = ProcessInfo.processInfo.environment["CRUFT_HOME"]
        let homeURL = (home ?? envHome).map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return ScanContext(
            home: homeURL,
            projectsRoot: projectsRoot.map { URL(filePath: $0) },
            excludedSourceIDs: Set(exclude.map { CategoryID($0) })
        )
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover and size all cache categories."
    )

    @OptionGroup var context: ContextOptions

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON (schema frozen, see source header).")
    var json = false

    func run() async throws {
        try await runScan()
    }
}

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clean one cache category. DRY-RUN by default; pass --yes to delete."
    )

    @OptionGroup var context: ContextOptions

    @Option(name: .customLong("category"), help: "Category id to clean (see scan output).")
    var category: String

    @Flag(name: .customLong("dry-run"), help: "Validate and list what would be deleted (the default behavior).")
    var dryRun = false

    @Flag(name: .customLong("yes"), help: "Actually delete. Without this flag clean only performs a dry run.")
    var yes = false

    /// Hidden second gate for live cleans of the REAL home directory;
    /// fixture homes under the system temp areas need only `--yes`.
    @Flag(name: .customLong("really"), help: .hidden)
    var really = false

    func run() async throws {
        try await runClean()
    }
}

struct Fixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Materialize the canonical test fixture home at PATH (testing/verification harness)."
    )

    @Argument(help: "Directory to create the fixture home in.")
    var path: String

    func run() async throws {
        try runFixture()
    }
}
