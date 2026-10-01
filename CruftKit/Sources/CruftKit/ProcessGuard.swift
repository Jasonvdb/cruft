import AppKit
import Foundation

/// Injectable process-query seam so ProcessGuard tests are hermetic (whether
/// Xcode is running differs between dev machines, verifier worktrees, and CI).
public protocol ProcessQuerying: Sendable {
    func runningAppBundleIDs() -> Set<String>
    func processCommandLines() -> [String]
}

/// Real implementation backed by NSWorkspace and `pgrep`.
public struct SystemProcessQuerier: ProcessQuerying {
    public init() {}

    public func runningAppBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Full command lines of every visible process via `pgrep -fl .`. Any
    /// spawn or decode failure degrades to an empty list — ProcessGuard is
    /// warn-only, so a missed warning is acceptable and a crash is not.
    public func processCommandLines() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "."]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").map { line in
            // Each line is "<pid> <command line>"; strip the pid prefix.
            String(line.drop(while: { $0 == " " })
                .drop(while: \.isNumber)
                .drop(while: { $0 == " " }))
        }
    }
}

/// Warn-only in v1: detects tools that may be actively writing into a cache
/// category (Xcode for DerivedData/Xcode misc, Gradle daemons for Gradle).
/// Clean confirmations surface these warnings; nothing is blocked.
public struct ProcessGuard: Sendable {
    /// Categories Xcode actively writes into while building or archiving.
    private static let xcodeCategories: Set<CategoryID> = [
        CategoryID("derived-data"), CategoryID("xcode-misc"), CategoryID("xcode-archives"),
        CategoryID("simulator-device-data"), CategoryID("temporary-derived-data"),
        CategoryID("other-derived-data"), CategoryID("simulator-logs"),
        CategoryID("xctest-devices"), CategoryID("device-install-cache"),
        CategoryID("simulator-runtimes"),
    ]
    /// Categories that a command-line build writes into without Xcode.app.
    private static let xcodebuildCategories: Set<CategoryID> = [
        CategoryID("derived-data"), CategoryID("other-derived-data"),
        CategoryID("temporary-derived-data"), CategoryID("xctest-devices"),
    ]
    private static let gradleCategory = CategoryID("gradle")
    private static let pythonCategory = CategoryID("python-cache")
    private static let pythonTools: Set<String> = ["uv", "uvx", "pip", "pip3"]
    private static let xcodeBundleID = "com.apple.dt.Xcode"

    private let querier: any ProcessQuerying

    public init(querier: any ProcessQuerying = SystemProcessQuerier()) {
        self.querier = querier
    }

    /// Human-readable warnings for the categories about to be cleaned. The
    /// querier is only consulted for the checks the category set actually
    /// requires (no `pgrep` spawn unless Gradle is being cleaned).
    public func warnings(for categories: Set<CategoryID>) -> [String] {
        var warnings: [String] = []
        if !categories.isDisjoint(with: Self.xcodeCategories),
            querier.runningAppBundleIDs().contains(Self.xcodeBundleID)
        {
            warnings.append("Xcode is running — cleaning may break in-progress builds.")
        }
        if categories.contains(Self.gradleCategory),
            querier.processCommandLines().contains(where: { $0.contains("GradleDaemon") })
        {
            warnings.append(
                "A Gradle daemon is running — cleaning may break in-progress builds (run ./gradlew --stop first).")
        }
        if !categories.isDisjoint(with: Self.xcodebuildCategories),
            querier.processCommandLines().contains(where: { Self.executableName($0) == "xcodebuild" })
        {
            warnings.append("xcodebuild is running — cleaning may break a command-line build or test run.")
        }
        if categories.contains(Self.pythonCategory),
            querier.processCommandLines().contains(where: {
                Self.pythonTools.contains(Self.executableName($0))
            })
        {
            warnings.append("uv or pip is running — cruft will refuse files that are still in use.")
        }
        return warnings
    }

    /// The last path component of a command line's first word.
    private static func executableName(_ commandLine: String) -> String {
        let executable = commandLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return executable.split(separator: "/").last.map(String.init) ?? executable
    }
}
