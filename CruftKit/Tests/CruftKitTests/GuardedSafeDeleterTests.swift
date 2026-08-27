import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private struct FixedGuardedMeasurer: DirectoryMeasurer {
    let size: ItemSize

    func measure(
        _ root: URL,
        partial: @Sendable (ItemSize) -> Void
    ) async throws -> ItemSize {
        size
    }
}

private struct StubGuardedUseChecker: GuardedArtifactUseChecking {
    let inUse: Bool
    func isInUse(_ target: URL) throws -> Bool { inUse }
}

private struct StubGuardedWorktreeManager: AgentWorktreeManaging {
    let current: AgentWorktreeMetadata?

    func inspect(
        target: URL,
        repositoryRoot: URL,
        agent: AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata? {
        current
    }

    func remove(target: URL, metadata: AgentWorktreeMetadata) throws {}
}

@Suite("Guarded SafeDeleter modes")
struct GuardedSafeDeleterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func oldUnusedTemporaryDerivedDataDeletesThroughChokePoint() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let target = try fixture.plantTemporaryDerivedDataFixture()
        let deleter = try makeDeleter(
            home: fixture.root,
            mode: .live,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60))
        let expectedTarget = target.cruftCanonical

        let deleted = try await deleter.delete(temporaryRequest(target, fixture: fixture))

        #expect(deleted == [expectedTarget])
        #expect(!fixture.exists(FixtureHome.temporaryDerivedDataFixturePath))
        #expect(fixture.exists("private-tmp"))
    }

    @Test func recentOrActiveTemporaryDerivedDataIsRefused() async throws {
        let recentFixture = try FixtureHome.makeTemporary()
        defer { try? recentFixture.destroy() }
        let recentTarget = try recentFixture.plantTemporaryDerivedDataFixture()
        let recent = try makeDeleter(
            home: recentFixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-2 * 24 * 60 * 60))
        await #expect(throws: SafeDeleterError.minimumAgeNotMet(
            recentTarget.cruftCanonical.path(percentEncoded: false))) {
            try await recent.delete(temporaryRequest(recentTarget, fixture: recentFixture))
        }

        let activeFixture = try FixtureHome.makeTemporary()
        defer { try? activeFixture.destroy() }
        let activeTarget = try activeFixture.plantTemporaryDerivedDataFixture()
        let active = try makeDeleter(
            home: activeFixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
            inUse: true)
        await #expect(throws: SafeDeleterError.activeUseDetected(
            activeTarget.cruftCanonical.path(percentEncoded: false))) {
            try await active.delete(temporaryRequest(activeTarget, fixture: activeFixture))
        }
        #expect(activeFixture.exists(FixtureHome.temporaryDerivedDataFixturePath))
    }

    @Test func wrongTemporaryRootAndChangedSignatureAreRefused() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let wrong = try fixture.plantDir("other/Fake-DerivedData")
        try fixture.plantDir("other/Fake-DerivedData/Build")
        try fixture.plantDir("other/Fake-DerivedData/Logs")
        let deleter = try makeDeleter(
            home: fixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60))
        let wrongItem = CacheItem(
            categoryID: TemporaryDerivedDataSource.id,
            url: wrong,
            label: wrong.lastPathComponent,
            deletionMode: .temporaryDerivedData)
        await #expect(throws: SafeDeleterError.guardedTargetInvalid(
            wrong.path(percentEncoded: false))) {
            try await deleter.delete(DeletionRequest(
                item: wrongItem,
                allowedRoots: [wrong.deletingLastPathComponent()]))
        }

        let target = try fixture.plantTemporaryDerivedDataFixture()
        try FileManager.default.removeItem(at: target.appending(path: "Build"))
        await #expect(throws: SafeDeleterError.guardedTargetInvalid(
            target.path(percentEncoded: false))) {
            try await deleter.delete(temporaryRequest(target, fixture: fixture))
        }
    }

    @Test func exactOldUnusedWorktreeDryRunRecordsWithoutRemoving() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let root = try fixture.plantDir("Documents/Repositories/Demo/.codex/worktrees")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/legacy")
        let metadata = safeMetadata(repository: repository)
        let deleter = try makeDeleter(
            home: fixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
            metadata: metadata)

        let deleted = try await deleter.delete(worktreeRequest(
            target: target, root: root, metadata: metadata))

        #expect(deleted == [target.cruftCanonical])
        #expect(fixture.exists("Documents/Repositories/Demo/.codex/worktrees/legacy"))
    }

    @Test func activeOrChangedWorktreeStateIsRefused() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let root = try fixture.plantDir("Documents/Repositories/Demo/.codex/worktrees")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/legacy")
        let retained = safeMetadata(repository: repository)
        let active = try makeDeleter(
            home: fixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
            inUse: true,
            metadata: retained)
        await #expect(throws: SafeDeleterError.activeUseDetected(
            target.cruftCanonical.path(percentEncoded: false))) {
            try await active.delete(worktreeRequest(
                target: target, root: root, metadata: retained))
        }

        let changed = AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: repository,
            headRevision: String(repeating: "c", count: 40),
            branchName: "legacy",
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: false,
            isLocked: false,
            isContainedInPrimaryBranch: true)
        let changedDeleter = try makeDeleter(
            home: fixture.root,
            mode: .dryRun,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
            metadata: changed)
        await #expect(throws: SafeDeleterError.guardedTargetInvalid(
            target.path(percentEncoded: false))) {
            try await changedDeleter.delete(worktreeRequest(
                target: target, root: root, metadata: retained))
        }
    }

    private func makeDeleter(
        home: URL,
        mode: SafeDeleter.Mode,
        modifiedAt: Date,
        inUse: Bool = false,
        metadata: AgentWorktreeMetadata? = nil
    ) throws -> SafeDeleter {
        let currentNow = now
        return try SafeDeleter(
            home: home,
            mode: mode,
            simulatorCommandRunner: SimctlSimulatorDeviceCommandRunner(),
            simulatorDeviceTypeNames: SystemSimulatorDeviceTypeNameProvider(),
            guardedUseChecker: StubGuardedUseChecker(inUse: inUse),
            worktreeManager: StubGuardedWorktreeManager(current: metadata),
            measurer: FixedGuardedMeasurer(size: ItemSize(
                allocatedBytes: 4096,
                fileCount: 1,
                newestModificationDate: modifiedAt)),
            now: { currentNow })
    }

    private func temporaryRequest(
        _ target: URL,
        fixture: FixtureHome
    ) -> DeletionRequest {
        DeletionRequest(
            item: CacheItem(
                categoryID: TemporaryDerivedDataSource.id,
                url: target,
                label: target.lastPathComponent,
                deletionMode: .temporaryDerivedData),
            allowedRoots: [fixture.url("private-tmp")])
    }

    private func safeMetadata(repository: URL) -> AgentWorktreeMetadata {
        AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: repository,
            headRevision: String(repeating: "b", count: 40),
            branchName: "legacy",
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: true,
            isLocked: false,
            isContainedInPrimaryBranch: true)
    }

    private func worktreeRequest(
        target: URL,
        root: URL,
        metadata: AgentWorktreeMetadata
    ) -> DeletionRequest {
        DeletionRequest(
            item: CacheItem(
                categoryID: AgentWorktreeSource.id,
                url: target,
                label: "Demo / Codex / legacy",
                deletionMode: .agentWorktree,
                agentWorktreeMetadata: metadata),
            allowedRoots: [root])
    }
}
