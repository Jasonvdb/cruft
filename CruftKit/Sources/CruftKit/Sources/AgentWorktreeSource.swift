import Foundation

protocol AgentWorktreeManaging: Sendable {
    func inspect(
        target: URL,
        repositoryRoot: URL,
        agent: AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata?

    func remove(target: URL, metadata: AgentWorktreeMetadata) throws
}

/// Local Git adapter shared by discovery and delete-time validation. It never
/// contacts a remote. Removal deliberately omits `--force`, so Git adds its
/// own final dirty/locked refusal after Cruft's checks.
struct SystemAgentWorktreeManager: AgentWorktreeManaging {
    enum ManagerError: Error, Equatable {
        case removeFailed(Int32, String)
    }

    private let runner: any DirectProcessRunning

    init(runner: any DirectProcessRunning = BoundedDirectProcessRunner(timeout: 10)) {
        self.runner = runner
    }

    func inspect(
        target: URL,
        repositoryRoot: URL,
        agent: AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata? {
        let target = target.cruftCanonical
        let repositoryRoot = repositoryRoot.cruftCanonical
        guard let records = worktreeRecords(repositoryRoot: repositoryRoot),
            let record = records.first(where: {
                normalizedPath($0.path.cruftCanonical) == normalizedPath(target)
            }),
            record.head.count == 40,
            record.head.allSatisfy({ $0.isHexDigit })
        else { return nil }

        let status = runGit(
            repositoryRoot: target,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        guard let status, status.status == 0, !status.outputWasTruncated else { return nil }
        let isClean = status.standardOutput.isEmpty
        let primaryReference = primaryReference(repositoryRoot: repositoryRoot)
        let isContained: Bool
        if let primaryReference {
            let mergeBase = runGit(
                repositoryRoot: repositoryRoot,
                arguments: ["merge-base", "--is-ancestor", record.head, primaryReference])
            isContained = mergeBase?.status == 0
        } else {
            isContained = false
        }

        return AgentWorktreeMetadata(
            agent: agent,
            repositoryRoot: repositoryRoot,
            headRevision: record.head,
            branchName: record.branch.map {
                $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0
            },
            primaryReference: primaryReference,
            isRegistered: true,
            isClean: isClean,
            isLocked: record.isLocked,
            isContainedInPrimaryBranch: isContained)
    }

    func remove(target: URL, metadata: AgentWorktreeMetadata) throws {
        let result = runGit(
            repositoryRoot: metadata.repositoryRoot,
            arguments: [
                "worktree", "remove", "--",
                target.cruftCanonical.path(percentEncoded: false),
            ])
        guard let result, result.status == 0, !result.outputWasTruncated else {
            let message = result.map {
                String(decoding: $0.standardError.prefix(2048), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? "Git could not start."
            throw ManagerError.removeFailed(result?.status ?? -1, message)
        }
    }

    private struct WorktreeRecord {
        var path: URL
        var head = ""
        var branch: String?
        var isLocked = false
    }

    private func worktreeRecords(repositoryRoot: URL) -> [WorktreeRecord]? {
        guard let result = runGit(
            repositoryRoot: repositoryRoot,
            arguments: ["worktree", "list", "--porcelain", "-z"]),
            result.status == 0,
            !result.outputWasTruncated,
            let output = String(data: result.standardOutput, encoding: .utf8)
        else { return nil }

        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?
        for rawField in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let field = String(rawField)
            if field.isEmpty {
                if let record = current { records.append(record) }
                current = nil
            } else if field.hasPrefix("worktree ") {
                if let record = current { records.append(record) }
                current = WorktreeRecord(
                    path: URL(filePath: String(field.dropFirst("worktree ".count)),
                        directoryHint: .isDirectory))
            } else if field.hasPrefix("HEAD ") {
                current?.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                current?.branch = String(field.dropFirst("branch ".count))
            } else if field == "locked" || field.hasPrefix("locked ") {
                current?.isLocked = true
            }
        }
        if let current { records.append(current) }
        return records
    }

    private func primaryReference(repositoryRoot: URL) -> String? {
        var candidates = ["refs/heads/main", "refs/heads/master"]
        if let remoteHead = runGit(
            repositoryRoot: repositoryRoot,
            arguments: ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]),
            remoteHead.status == 0,
            let reference = String(data: remoteHead.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !reference.isEmpty
        {
            candidates.append(reference)
        }
        candidates.append("refs/heads/develop")

        for candidate in candidates {
            let result = runGit(
                repositoryRoot: repositoryRoot,
                arguments: ["rev-parse", "--verify", "--quiet", candidate])
            if result?.status == 0 { return candidate }
        }
        return nil
    }

    private func runGit(
        repositoryRoot: URL,
        arguments: [String]
    ) -> DirectProcessResult? {
        try? runner.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", repositoryRoot.path(percentEncoded: false)] + arguments)
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Registered Git worktrees stored under a repository's direct
/// `.claude/worktrees` or `.codex/worktrees` directory. Cleanup is explicit
/// per item and requires clean, unlocked, primary-branch-contained Git state.
public struct AgentWorktreeSource: CacheSource {
    public static let id = CategoryID("agent-worktrees")
    public static let warning =
        "Worktree deletion removes its checked-out files. Cruft rechecks Git state and active use, and never uses force."

    public let displayName = "Claude & Codex Worktrees"
    public let includedInCleanAllByDefault = false
    public let isDestructive = true
    public let allowsWholeCategoryCleaning = false
    public let destructiveWarning: String? = Self.warning
    public let defersScheduledScanForRecentRootActivity = false

    private let manager: any AgentWorktreeManaging

    public init() {
        self.manager = SystemAgentWorktreeManager()
    }

    init(manager: any AgentWorktreeManaging) {
        self.manager = manager
    }

    public func scanRoot(context: ScanContext) -> URL? { context.projectsRoot }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        worktreeRoots(context: context).map(\.url)
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id
            && item.deletionMode == .agentWorktree
            && item.agentWorktreeMetadata?.isEligibleForDeletion == true
    }

    public func canClean(measuredItem: MeasuredItem) -> Bool {
        canClean(item: measuredItem.item)
            && GuardedCleanupPolicy.hasCompleteOldMeasurement(measuredItem.size)
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        var items: [CacheItem] = []
        for root in worktreeRoots(context: context) {
            try Task.checkCancellation()
            let entries = try FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            for listed in entries {
                try Task.checkCancellation()
                let target = root.url.appending(path: listed.lastPathComponent)
                guard Self.isUnsymlinkedRealDirectory(target),
                    let metadata = manager.inspect(
                        target: target,
                        repositoryRoot: root.repositoryRoot,
                        agent: root.agent)
                else { continue }
                items.append(CacheItem(
                    categoryID: Self.id,
                    url: target,
                    label: "\(root.repositoryRoot.lastPathComponent) / "
                        + "\(root.agent.displayName) / \(target.lastPathComponent)",
                    deletionMode: .agentWorktree,
                    agentWorktreeMetadata: metadata))
            }
        }
        return items.sorted {
            $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false)
        }
    }

    private struct WorktreeRoot {
        let url: URL
        let repositoryRoot: URL
        let agent: AgentWorktreeMetadata.Agent
    }

    private func worktreeRoots(context: ScanContext) -> [WorktreeRoot] {
        let projectsRoot = context.projectsRoot
        guard Self.isUnsymlinkedRealDirectory(projectsRoot) else { return [] }
        var repositories: [URL] = [projectsRoot]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        {
            repositories += entries.compactMap { listed in
                let candidate = projectsRoot.appending(path: listed.lastPathComponent)
                return Self.isUnsymlinkedRealDirectory(candidate) ? candidate : nil
            }
        }

        var roots: [WorktreeRoot] = []
        for repository in repositories {
            for agent in [AgentWorktreeMetadata.Agent.claude, .codex] {
                let root = repository
                    .appending(path: ".\(agent.rawValue)")
                    .appending(path: "worktrees")
                guard Self.isUnsymlinkedRealDirectory(root) else { continue }
                roots.append(WorktreeRoot(url: root, repositoryRoot: repository, agent: agent))
            }
        }
        return roots.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    private static func isUnsymlinkedRealDirectory(_ url: URL) -> Bool {
        let standardized = normalizedPath(url.standardizedFileURL)
        let canonical = normalizedPath(url.cruftCanonical)
        guard standardized == canonical else { return false }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
