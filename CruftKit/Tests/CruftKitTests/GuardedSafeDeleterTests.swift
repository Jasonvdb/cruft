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

/// Records what the choke point asked Git to do, so the `--force` decision is
/// asserted directly rather than inferred from a deletion succeeding.
private final class StubGuardedWorktreeManager: AgentWorktreeManaging, @unchecked Sendable {
    let current: AgentWorktreeMetadata?
    private let lock = NSLock()
    private var recordedForce: [Bool] = []

    init(current: AgentWorktreeMetadata?) {
        self.current = current
    }

    var forceRequests: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedForce
    }

    func inspect(
        target: URL,
        repositoryRoot: URL,
        agent: AgentWorktreeMetadata.Agent
    ) -> AgentWorktreeMetadata? {
        current
    }

    func remove(target: URL, metadata: AgentWorktreeMetadata, force: Bool) throws {
        lock.lock()
        recordedForce.append(force)
        lock.unlock()
        try FileManager.default.removeItem(at: target)
    }
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

    @Test func dirtyWorktreeIsRefusedByDefaultAndForcedOnlyUnderTheOptIn() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let root = try fixture.plantDir("Documents/Repositories/Demo/.codex/worktrees")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/legacy")
        let dirty = dirtyMetadata(repository: repository)
        let old = now.addingTimeInterval(-4 * 24 * 60 * 60)
        // Canonicalize while the directory still exists: a deleted path keeps
        // its trailing slash.
        let expectedTarget = target.cruftCanonical

        let strictManager = StubGuardedWorktreeManager(current: dirty)
        let strict = try makeDeleter(
            home: fixture.root, mode: .live, modifiedAt: old, manager: strictManager)
        await #expect(throws: SafeDeleterError.guardedTargetInvalid(
            target.path(percentEncoded: false))) {
            try await strict.delete(worktreeRequest(
                target: target, root: root, metadata: dirty))
        }
        #expect(strictManager.forceRequests.isEmpty)
        #expect(fixture.exists("Documents/Repositories/Demo/.codex/worktrees/legacy"))

        let permissiveManager = StubGuardedWorktreeManager(current: dirty)
        let permissive = try makeDeleter(
            home: fixture.root,
            mode: .live,
            modifiedAt: old,
            manager: permissiveManager,
            policy: .permissive)

        let deleted = try await permissive.delete(worktreeRequest(
            target: target, root: root, metadata: dirty))

        #expect(deleted == [expectedTarget])
        #expect(permissiveManager.forceRequests == [true])
        #expect(!fixture.exists("Documents/Repositories/Demo/.codex/worktrees/legacy"))
    }

    @Test func cleanWorktreeIsNeverForcedEvenUnderTheOptIn() async throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let root = try fixture.plantDir("Documents/Repositories/Demo/.codex/worktrees")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/legacy")
        let metadata = safeMetadata(repository: repository)
        let manager = StubGuardedWorktreeManager(current: metadata)
        let deleter = try makeDeleter(
            home: fixture.root,
            mode: .live,
            modifiedAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
            manager: manager,
            policy: .permissive)

        _ = try await deleter.delete(worktreeRequest(
            target: target, root: root, metadata: metadata))

        #expect(manager.forceRequests == [false])
    }

    @Test func theOptInWaivesNeitherAgeNorActiveUseNorTheLock() async throws {
        let old = now.addingTimeInterval(-4 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)

        // Recent: the 72-hour gate still fires.
        let recentFixture = try FixtureHome.makeTemporary()
        defer { try? recentFixture.destroy() }
        let recentCase = try plantWorktree(in: recentFixture)
        let recentDeleter = try makeDeleter(
            home: recentFixture.root,
            mode: .dryRun,
            modifiedAt: recent,
            manager: StubGuardedWorktreeManager(
                current: dirtyMetadata(repository: recentCase.repository)),
            policy: .permissive)
        await #expect(throws: SafeDeleterError.minimumAgeNotMet(
            recentCase.target.cruftCanonical.path(percentEncoded: false))) {
            try await recentDeleter.delete(worktreeRequest(
                target: recentCase.target,
                root: recentCase.root,
                metadata: dirtyMetadata(repository: recentCase.repository)))
        }

        // In use: the live process check still fires.
        let activeFixture = try FixtureHome.makeTemporary()
        defer { try? activeFixture.destroy() }
        let activeCase = try plantWorktree(in: activeFixture)
        let activeDeleter = try makeDeleter(
            home: activeFixture.root,
            mode: .dryRun,
            modifiedAt: old,
            inUse: true,
            manager: StubGuardedWorktreeManager(
                current: dirtyMetadata(repository: activeCase.repository)),
            policy: .permissive)
        await #expect(throws: SafeDeleterError.activeUseDetected(
            activeCase.target.cruftCanonical.path(percentEncoded: false))) {
            try await activeDeleter.delete(worktreeRequest(
                target: activeCase.target,
                root: activeCase.root,
                metadata: dirtyMetadata(repository: activeCase.repository)))
        }

        // Locked: never waivable.
        let lockedFixture = try FixtureHome.makeTemporary()
        defer { try? lockedFixture.destroy() }
        let lockedCase = try plantWorktree(in: lockedFixture)
        let locked = AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: lockedCase.repository,
            headRevision: String(repeating: "b", count: 40),
            branchName: "legacy",
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: false,
            isLocked: true,
            isContainedInPrimaryBranch: false)
        let lockedDeleter = try makeDeleter(
            home: lockedFixture.root,
            mode: .dryRun,
            modifiedAt: old,
            manager: StubGuardedWorktreeManager(current: locked),
            policy: .permissive)
        await #expect(throws: SafeDeleterError.guardedTargetInvalid(
            lockedCase.target.path(percentEncoded: false))) {
            try await lockedDeleter.delete(worktreeRequest(
                target: lockedCase.target, root: lockedCase.root, metadata: locked))
        }
    }

    private func plantWorktree(
        in fixture: FixtureHome
    ) throws -> (repository: URL, root: URL, target: URL) {
        let repository = try fixture.plantDir("Documents/Repositories/Demo")
        let root = try fixture.plantDir("Documents/Repositories/Demo/.codex/worktrees")
        let target = try fixture.plantDir(
            "Documents/Repositories/Demo/.codex/worktrees/legacy")
        return (repository, root, target)
    }

    private func makeDeleter(
        home: URL,
        mode: SafeDeleter.Mode,
        modifiedAt: Date,
        inUse: Bool = false,
        metadata: AgentWorktreeMetadata? = nil,
        manager: StubGuardedWorktreeManager? = nil,
        policy: AgentWorktreeDeletionPolicy = .strict
    ) throws -> SafeDeleter {
        let currentNow = now
        return try SafeDeleter(
            home: home,
            mode: mode,
            simulatorCommandRunner: SimctlSimulatorDeviceCommandRunner(),
            simulatorDeviceTypeNames: SystemSimulatorDeviceTypeNameProvider(),
            guardedUseChecker: StubGuardedUseChecker(inUse: inUse),
            worktreeManager: manager ?? StubGuardedWorktreeManager(current: metadata),
            measurer: FixedGuardedMeasurer(size: ItemSize(
                allocatedBytes: 4096,
                fileCount: 1,
                newestModificationDate: modifiedAt)),
            now: { currentNow },
            agentWorktreePolicy: policy)
    }

    private func dirtyMetadata(repository: URL) -> AgentWorktreeMetadata {
        AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: repository,
            headRevision: String(repeating: "b", count: 40),
            branchName: "legacy",
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: false,
            isLocked: false,
            isContainedInPrimaryBranch: false)
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
