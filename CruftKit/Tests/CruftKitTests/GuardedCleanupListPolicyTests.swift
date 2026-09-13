import Foundation
import Testing
@testable import CruftKit

// The presentation split behind the worktree opt-in: which refusals still
// block a row, which the user has waived, and what stays visible either way.

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let old = now.addingTimeInterval(-4 * 24 * 60 * 60)

private func worktreeItem(
    name: String,
    isClean: Bool,
    isLocked: Bool = false,
    isContained: Bool,
    modifiedAt: Date = old
) -> MeasuredItem {
    let repository = URL(filePath: "/tmp/cruft-fixture/Demo", directoryHint: .isDirectory)
    let item = CacheItem(
        categoryID: AgentWorktreeSource.id,
        url: repository.appending(path: ".codex/worktrees/\(name)"),
        label: "Demo / Codex / \(name)",
        deletionMode: .agentWorktree,
        agentWorktreeMetadata: AgentWorktreeMetadata(
            agent: .codex,
            repositoryRoot: repository,
            headRevision: String(repeating: "a", count: 40),
            branchName: name,
            primaryReference: "refs/heads/main",
            isRegistered: true,
            isClean: isClean,
            isLocked: isLocked,
            isContainedInPrimaryBranch: isContained))
    return MeasuredItem(
        item: item,
        size: ItemSize(
            allocatedBytes: 4096, fileCount: 1, newestModificationDate: modifiedAt))
}

@Test func strictPolicyBlocksDirtyAndUnmergedRows() {
    let snapshot = CategorySnapshot(
        categoryID: AgentWorktreeSource.id,
        items: [
            worktreeItem(name: "dirty", isClean: false, isContained: true),
            worktreeItem(name: "unmerged", isClean: true, isContained: false),
        ])

    let list = GuardedCleanupList(snapshot: snapshot, now: now)

    #expect(list.rows.allSatisfy { !$0.isDeletable })
    #expect(list.rows.allSatisfy { $0.waivedReasons.isEmpty })
    #expect(list.rows[0].blockingReasons == [.dirty])
    #expect(list.rows[1].blockingReasons == [.notContainedInPrimaryBranch])
}

@Test func optInMovesDirtyAndUnmergedFromBlockingToWaived() {
    let snapshot = CategorySnapshot(
        categoryID: AgentWorktreeSource.id,
        items: [worktreeItem(name: "both", isClean: false, isContained: false)])

    let list = GuardedCleanupList(snapshot: snapshot, policy: .permissive, now: now)
    let row = try! #require(list.rows.first)

    #expect(row.isDeletable)
    #expect(row.blockingReasons.isEmpty)
    #expect(row.waivedReasons == [.dirty, .notContainedInPrimaryBranch])
    // The badge stays: waiving a reason never hides it.
    #expect(row.discardsUncommittedWork)
}

@Test func optInWaivesNothingBesidesTheTwoGitRefusals() {
    let snapshot = CategorySnapshot(
        categoryID: AgentWorktreeSource.id,
        items: [
            worktreeItem(
                name: "recent", isClean: false, isContained: false,
                modifiedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)),
            worktreeItem(name: "locked", isClean: false, isLocked: true, isContained: false),
        ])

    let list = GuardedCleanupList(snapshot: snapshot, policy: .permissive, now: now)

    // Rows sort by label, so "locked" comes before "recent".
    #expect(list.rows.allSatisfy { !$0.isDeletable })
    #expect(list.rows[0].blockingReasons == [.locked])
    #expect(list.rows[1].blockingReasons == [.recent])
    // Even on a blocked row the waived facts are still reported.
    #expect(list.rows[0].waivedReasons == [.dirty, .notContainedInPrimaryBranch])
}

@Test func temporaryDerivedDataRowsAreUnaffectedByTheWorktreePolicy() {
    let item = CacheItem(
        categoryID: TemporaryDerivedDataSource.id,
        url: URL(filePath: "/private/tmp/Demo-abcdef", directoryHint: .isDirectory),
        label: "Demo-abcdef",
        deletionMode: .temporaryDerivedData)
    let snapshot = CategorySnapshot(
        categoryID: TemporaryDerivedDataSource.id,
        items: [MeasuredItem(
            item: item,
            size: ItemSize(
                allocatedBytes: 4096, fileCount: 1, newestModificationDate: old))])

    let list = GuardedCleanupList(snapshot: snapshot, policy: .permissive, now: now)
    let row = try! #require(list.rows.first)

    #expect(row.isDeletable)
    #expect(row.waivedReasons.isEmpty)
}
