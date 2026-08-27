import Foundation

protocol GuardedArtifactUseChecking: Sendable {
    func isInUse(_ target: URL) throws -> Bool
}

struct SystemGuardedArtifactUseChecker: GuardedArtifactUseChecking {
    enum CheckError: Error, Equatable {
        case inspectionFailed(String)
    }

    private let runner: any DirectProcessRunning

    init(runner: any DirectProcessRunning = BoundedDirectProcessRunner(
        timeout: 15, maximumOutputBytes: 2 * 1024 * 1024)
    ) {
        self.runner = runner
    }

    func isInUse(_ target: URL) throws -> Bool {
        let canonical = target.cruftCanonical
        let path = normalizedPath(canonical)
        let openFiles = try runner.run(
            executable: URL(filePath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-F", "p", "+D", path])
        guard !openFiles.outputWasTruncated else {
            throw CheckError.inspectionFailed("lsof output was truncated")
        }
        if openFiles.status == 0, !openFiles.standardOutput.isEmpty { return true }
        if openFiles.status != 1 || !openFiles.standardError.isEmpty {
            let message = String(decoding: openFiles.standardError.prefix(1024), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckError.inspectionFailed(message.isEmpty ? "lsof failed" : message)
        }

        let processes = try runner.run(
            executable: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-fl", "."])
        guard !processes.outputWasTruncated,
            processes.status == 0 || processes.status == 1
        else {
            throw CheckError.inspectionFailed("process inspection failed")
        }
        let aliases = pathAliases(path)
        let commandLines = String(decoding: processes.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        return commandLines.contains { command in
            aliases.contains(where: command.contains)
        }
    }

    private func pathAliases(_ path: String) -> [String] {
        var aliases = [path]
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            aliases.append("/private" + path)
        } else if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
            aliases.append(String(path.dropFirst("/private".count)))
        }
        return aliases
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
