import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private struct StubAgentWorktreeManager: AgentWorktreeManaging {
    let operation: @Sendable (
        URL, URL, AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata?

    func inspect(
        target: URL,
        repositoryRoot: URL,
        agent: AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata? {
        operation(target, repositoryRoot, agent)
    }

    func remove(target: URL, metadata: AgentWorktreeMetadata) throws {}
}

@Suite("AgentWorktreeSource")
struct AgentWorktreeSourceTests {
    @Test func discoversOnlyRegisteredDirectClaudeAndCodexWorktrees() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let codex = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/old-clean")
        let claude = try fixture.plantDir(
            "Documents/Repositories/Demo/.claude/worktrees/dirty")
        try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/not-registered")
        let outside = try fixture.plantDir("outside-linked-worktree")
        try fixture.plantSymlink(
            at: "Documents/Repositories/Demo/.codex/worktrees/linked",
            to: outside.path(percentEncoded: false))

        let manager = StubAgentWorktreeManager { target, repo, agent in
            guard target.lastPathComponent != "not-registered" else { return nil }
            return AgentWorktreeMetadata(
                agent: agent,
                repositoryRoot: repo,
                headRevision: String(repeating: "a", count: 40),
                branchName: target.lastPathComponent,
                primaryReference: "refs/heads/main",
                isRegistered: true,
                isClean: target.lastPathComponent != "dirty",
                isLocked: false,
                isContainedInPrimaryBranch: true)
        }
        let source = AgentWorktreeSource(manager: manager)

        let items = try await source.discover(context: ScanContext(home: fixture.root))

        #expect(items.map(\.url) == [claude, codex])
        #expect(items.allSatisfy { $0.deletionMode == .agentWorktree })
        #expect(!source.canClean(item: try #require(items.first { $0.url == claude })))
        #expect(source.canClean(item: try #require(items.first { $0.url == codex })))
        #expect(items.allSatisfy {
            $0.agentWorktreeMetadata?.repositoryRoot == repository
        })
    }

    @Test func cleanContainedItemRoutesThroughSeamAndBulkPathsStayDisabled() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/old-clean")
        let metadata = AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: repository,
            headRevision: String(repeating: "b", count: 40),
            branchName: "old-clean",
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: true,
            isLocked: false,
            isContainedInPrimaryBranch: true)
        let source = AgentWorktreeSource(manager: StubAgentWorktreeManager { _, _, _ in metadata })
        let context = ScanContext(home: fixture.root)
        let item = try #require(try await source.discover(context: context).first)
        let deleter = RecordingDeleter()

        _ = try await source.clean(item: item, context: context, using: deleter)

        #expect(item.url == target)
        #expect(await deleter.requests.count == 1)
        #expect(source.supportsCleaning)
        #expect(!source.allowsWholeCategoryCleaning)
        #expect(!source.includedInCleanAllByDefault)
        #expect(source.isDestructive)
    }

    @Test func systemGitInspectorFindsCleanContainedWorktreeThenDetectsDirtyState() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        try runGit(repository, ["init", "-b", "main"])
        try runGit(repository, ["config", "user.name", "Cruft Tests"])
        try runGit(repository, ["config", "user.email", "cruft@example.invalid"])
        try fixture.plantFile("Documents/Repositories/Demo/.gitignore", bytes: 0)
        try Data(".codex/\n".utf8).write(to: repository.appending(path: ".gitignore"))
        try fixture.plantFile("Documents/Repositories/Demo/README.md")
        try runGit(repository, ["add", ".gitignore", "README.md"])
        try runGit(repository, ["commit", "-m", "fixture"])
        let target = repository.appending(path: ".codex/worktrees/legacy")
        try runGit(repository, [
            "worktree", "add", "-b", "legacy", target.path(percentEncoded: false), "main",
        ])
        let source = AgentWorktreeSource()
        let context = ScanContext(home: fixture.root)

        let clean = try #require(try await source.discover(context: context).first)
        #expect(clean.agentWorktreeMetadata?.isClean == true)
        #expect(clean.agentWorktreeMetadata?.isContainedInPrimaryBranch == true)

        try fixture.plantFile(
            "Documents/Repositories/Demo/.codex/worktrees/legacy/local.txt")
        let dirty = try #require(try await source.discover(context: context).first)
        #expect(dirty.agentWorktreeMetadata?.isClean == false)
        #expect(!source.canClean(item: dirty))
    }

    @Test func systemGitManagerRemovesCleanFixtureWorktreeWithoutForceAndKeepsBranch() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        try runGit(repository, ["init", "-b", "main"])
        try runGit(repository, ["config", "user.name", "Cruft Tests"])
        try runGit(repository, ["config", "user.email", "cruft@example.invalid"])
        try Data(".codex/\n".utf8).write(to: repository.appending(path: ".gitignore"))
        try fixture.plantFile("Documents/Repositories/Demo/README.md")
        try runGit(repository, ["add", ".gitignore", "README.md"])
        try runGit(repository, ["commit", "-m", "fixture"])
        let target = repository.appending(path: ".codex/worktrees/legacy")
        try runGit(repository, [
            "worktree", "add", "-b", "legacy", target.path(percentEncoded: false), "main",
        ])
        let manager = SystemAgentWorktreeManager()
        let metadata = try #require(manager.inspect(
            target: target,
            repositoryRoot: repository,
            agent: .codex))

        try manager.remove(target: target, metadata: metadata)

        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        let branch = try BoundedDirectProcessRunner(timeout: 10).run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: [
                "-C", repository.path(percentEncoded: false),
                "rev-parse", "--verify", "refs/heads/legacy",
            ])
        #expect(branch.status == 0)
    }

    private func runGit(_ repository: URL, _ arguments: [String]) throws {
        let result = try BoundedDirectProcessRunner(timeout: 10).run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", repository.path(percentEncoded: false)] + arguments)
        guard result.status == 0 else {
            throw SystemAgentWorktreeManager.ManagerError.removeFailed(
                result.status, String(decoding: result.standardError, as: UTF8.self))
        }
    }
}
