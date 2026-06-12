import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

/// End-to-end tests for the SafeDeleter choke point. Hermetic: every test
/// plants its own FixtureHome under a system temp area and cleans up
/// exclusively via FixtureHome.destroy().
@Suite struct SafeDeleterTests {
    private func request(
        url: URL, roots: [URL], deletionMode: DeletionMode = .entireItem
    ) -> DeletionRequest {
        DeletionRequest(
            item: CacheItem(
                categoryID: CategoryID("test"), url: url,
                label: url.lastPathComponent, deletionMode: deletionMode),
            allowedRoots: roots
        )
    }

    /// Runs a delete that MUST be refused and returns the rule that fired.
    private func refusal(_ deleter: SafeDeleter, _ request: DeletionRequest) async -> SafeDeleterError? {
        do {
            _ = try await deleter.delete(request)
            Issue.record("deletion unexpectedly allowed: \(request.item.url.path(percentEncoded: false))")
            return nil
        } catch let error as SafeDeleterError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }

    // MARK: - Rule 1: outside home

    @Test func symlinkEscapesHome() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let outside = try FixtureHome.makeTemporary()
        defer { try? outside.destroy() }
        try outside.plantFile("payload.bin")
        try home.plantSymlink(at: "Library/Caches/leak", to: outside.root.path(percentEncoded: false))

        // The leaf is a real file reached THROUGH a symlinked directory, so
        // canonical resolution lands outside the fixture home.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Caches/leak/payload.bin"),
            roots: [home.url("Library/Caches")])
        let error = await refusal(deleter, req)
        #expect(error?.ruleName == "outsideHome")
        #expect(outside.exists("payload.bin"))
    }

    // MARK: - Rule 4: denylist

    @Test func symlinkIntoGitDir() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Projects/repo/.git/objects/pack/data.bin")
        try home.plantSymlink(
            at: "Library/Caches/sneaky",
            to: home.url("Projects/repo/.git").path(percentEncoded: false))

        // The item resolves into a .git directory through the symlink; the
        // denylist must fire on the RESOLVED path even though the requested
        // path sits inside the allowed root.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Caches/sneaky/objects"),
            roots: [home.url("Library/Caches")])
        let error = await refusal(deleter, req)
        if case let .denylistedComponent(_, component) = error {
            #expect(component == ".git")
        } else {
            Issue.record("expected denylistedComponent, got \(String(describing: error))")
        }
        #expect(home.exists("Projects/repo/.git/objects/pack/data.bin"))
    }

    @Test(arguments: SafeDeleter.denylistedComponents)
    func denylistComponentWinsOverAllowedRoot(token: String) async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Caches/\(token)/payload.bin")

        // Inside an allowed root AND at legal depth — the denylist must
        // still win.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Caches/\(token)"),
            roots: [home.url("Library/Caches")])
        let error = await refusal(deleter, req)
        if case let .denylistedComponent(_, component) = error {
            #expect(component == token)
        } else {
            Issue.record("expected denylistedComponent for \(token), got \(String(describing: error))")
        }
        #expect(home.exists("Library/Caches/\(token)/payload.bin"))
    }

    @Test func contentsOnlyDenylistedChildAborts() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile(".npm/_cacache/content-v2/blob.bin")
        try home.plantDir(".npm/_cacache/.git")

        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url(".npm/_cacache"),
            roots: [home.url(".npm/_cacache")],
            deletionMode: .contentsOnly)
        let error = await refusal(deleter, req)
        if case let .denylistedComponent(_, component) = error {
            #expect(component == ".git")
        } else {
            Issue.record("expected denylistedComponent, got \(String(describing: error))")
        }
        // Validation is all-or-nothing: the clean sibling survives too and
        // nothing was recorded as deleted.
        #expect(home.exists(".npm/_cacache/content-v2/blob.bin"))
        #expect(home.exists(".npm/_cacache/.git"))
        let recorded = await deleter.deletedURLs
        #expect(recorded.isEmpty)
    }

    // MARK: - Rule 3: allowed roots

    @Test func outsideAllowedRootsRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Application Support/Important/data/file.bin")
        try home.plantFile("Library/CachesEvil/demo/payload.bin")

        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let elsewhere = request(
            url: home.url("Library/Application Support/Important/data"),
            roots: [home.url("Library/Caches")])
        #expect(await refusal(deleter, elsewhere)?.ruleName == "outsideAllowedRoots")
        #expect(home.exists("Library/Application Support/Important/data/file.bin"))

        // Sibling whose path merely string-prefixes the root must not match.
        let prefixCollision = request(
            url: home.url("Library/CachesEvil/demo"),
            roots: [home.url("Library/Caches")])
        #expect(await refusal(deleter, prefixCollision)?.ruleName == "outsideAllowedRoots")
        #expect(home.exists("Library/CachesEvil/demo/payload.bin"))
    }

    @Test func rootItselfRefusedUnlessExplicit() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Caches/npm/a.bin")
        try home.plantFile("Library/Caches/npm/pack/b.bin")
        let root = home.url("Library/Caches/npm")

        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let entire = request(url: root, roots: [root])
        #expect(await refusal(deleter, entire)?.ruleName == "rootItselfRefused")
        #expect(home.exists("Library/Caches/npm/a.bin"))

        // The same root as .contentsOnly is the explicit opt-in: children
        // go, the root survives.
        let contents = request(url: root, roots: [root], deletionMode: .contentsOnly)
        let deleted = try await deleter.delete(contents)
        #expect(deleted.count == 2)
        #expect(home.exists("Library/Caches/npm"))
        #expect(!home.exists("Library/Caches/npm/a.bin"))
        #expect(!home.exists("Library/Caches/npm/pack"))
    }

    // MARK: - Rule 5: depth floor

    @Test func depthFloorBelow3() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile(".gradle/caches/modules-2/dep.jar")

        // home/.gradle/caches is only 2 components below home.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(url: home.url(".gradle/caches"), roots: [home.url(".gradle")])
        #expect(await refusal(deleter, req)?.ruleName == "depthFloorViolated")
        #expect(home.exists(".gradle/caches/modules-2/dep.jar"))
    }

    // MARK: - Rule 7: existence and ownership

    @Test func nonexistentPath() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantDir("Library/Caches")

        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Caches/ghost"),
            roots: [home.url("Library/Caches")])
        #expect(await refusal(deleter, req)?.ruleName == "doesNotExist")
    }

    @Test func notOwnedByCurrentUser() throws {
        // Limitation: planting a fixture owned by another user requires
        // root (chown(2) to a foreign uid is privileged), so the refusal
        // branch cannot be reached through delete() in an unprivileged test
        // run. The rule's decision logic is exercised directly here with
        // injected uids; every happy-path test drives the passing branch
        // end-to-end through delete().
        let path = "/tmp/fixture/Library/Caches/x"
        #expect(throws: SafeDeleterError.notOwnedByCurrentUser(path)) {
            try SafeDeleter.validateOwnership(
                ownerUID: getuid() &+ 1, currentUID: getuid(), path: path)
        }
        // A target whose owner cannot be determined is refused, not assumed.
        #expect(throws: SafeDeleterError.notOwnedByCurrentUser(path)) {
            try SafeDeleter.validateOwnership(ownerUID: nil, currentUID: getuid(), path: path)
        }
        try SafeDeleter.validateOwnership(ownerUID: getuid(), currentUID: getuid(), path: path)
    }

    // MARK: - Rule 6: symlinked items

    @Test func symlinkedItemDeletesLinkOnly() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let outside = try FixtureHome.makeTemporary()
        defer { try? outside.destroy() }
        let destination = try outside.plantFile("payload.bin")
        try home.plantSymlink(
            at: "Library/Caches/link", to: destination.path(percentEncoded: false))

        // The link itself is the item: it is judged by its own (parent-
        // canonicalized) path, so it is deletable even though it points
        // outside home — and only the link goes.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Caches/link"),
            roots: [home.url("Library/Caches")])
        let deleted = try await deleter.delete(req)
        #expect(deleted.count == 1)
        #expect(!home.exists("Library/Caches/link"))
        #expect(outside.exists("payload.bin"))
    }

    // MARK: - Rule 2: home override

    @Test func homeOverrideToRootRefused() {
        #expect(throws: SafeDeleterError.homeOverrideRefused("/")) {
            _ = try SafeDeleter(home: URL(filePath: "/"), mode: .dryRun)
        }
    }

    @Test func homeOverrideToTmpAllowed() throws {
        let fixture = try FixtureHome.makeTemporary()
        defer { try? fixture.destroy() }
        // Fixture homes under the system temp areas are accepted…
        _ = try SafeDeleter(home: fixture.root, mode: .dryRun)
        // …and so is the real canonical $HOME (construction only; nothing
        // on the real disk is touched).
        _ = try SafeDeleter(home: FileManager.default.homeDirectoryForCurrentUser, mode: .dryRun)
    }

    // MARK: - Canonicalization

    @Test func fixtureHomeBehindPrivateSymlink() async throws {
        // /tmp is itself a symlink to /private/tmp. The fixture home is
        // created via the /tmp spelling while home and roots are handed
        // over in the /private spelling — cruftCanonical must converge all
        // of them or every prefix check here would refuse.
        let fixture = try FixtureHome(at: URL(filePath: "/tmp/cruft-sd-\(UUID().uuidString.prefix(8))"))
        defer { try? fixture.destroy() }
        try fixture.plantFile("Library/Caches/demo/payload.bin")

        let privateSpelling = { (url: URL) in
            URL(filePath: "/private" + url.path(percentEncoded: false))
        }
        let deleter = try SafeDeleter(home: privateSpelling(fixture.root), mode: .live)
        let req = request(
            url: fixture.url("Library/Caches/demo"),
            roots: [privateSpelling(fixture.url("Library/Caches"))])
        let deleted = try await deleter.delete(req)
        #expect(deleted.count == 1)
        #expect(!fixture.exists("Library/Caches/demo"))
        #expect(fixture.exists("Library/Caches"))
    }

    // MARK: - Happy paths

    @Test func entireItemSubdirDeleted() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Developer/Xcode/DerivedData/Demo-abc/file.bin")

        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Developer/Xcode/DerivedData/Demo-abc"),
            roots: [home.url("Library/Developer/Xcode/DerivedData")])
        let deleted = try await deleter.delete(req)
        #expect(deleted.count == 1)
        // Canonical directory URLs may carry a trailing slash.
        let deletedPath = deleted.first.map {
            $0.path(percentEncoded: false).hasSuffix("/")
                ? String($0.path(percentEncoded: false).dropLast())
                : $0.path(percentEncoded: false)
        }
        #expect(deletedPath?.hasSuffix("DerivedData/Demo-abc") == true)
        #expect(!home.exists("Library/Developer/Xcode/DerivedData/Demo-abc"))
        #expect(home.exists("Library/Developer/Xcode/DerivedData"))
        let recorded = await deleter.deletedURLs
        #expect(recorded == deleted)
    }

    @Test func contentsOnlyDeletesChildrenKeepsRoot() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile(".gradle/caches/modules-2/files-2.1/dep.jar")
        try home.plantFile(".gradle/caches/jars-9/x.bin")
        try home.plantFile(".gradle/caches/.hidden-marker")

        // The root is only 2 deep — legal for .contentsOnly because the
        // root survives and each child sits at depth 3.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url(".gradle/caches"),
            roots: [home.url(".gradle/caches")],
            deletionMode: .contentsOnly)
        let deleted = try await deleter.delete(req)
        #expect(deleted.count == 3)
        #expect(home.exists(".gradle/caches"))
        #expect(!home.exists(".gradle/caches/modules-2"))
        #expect(!home.exists(".gradle/caches/jars-9"))
        #expect(!home.exists(".gradle/caches/.hidden-marker"))
    }

    @Test func dryRunDeletesNothing() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Caches/demo/payload.bin")

        let deleter = try SafeDeleter(home: home.root, mode: .dryRun)
        let req = request(
            url: home.url("Library/Caches/demo"),
            roots: [home.url("Library/Caches")])
        let deleted = try await deleter.delete(req)
        #expect(deleted.count == 1)
        #expect(home.exists("Library/Caches/demo/payload.bin"))
        let recorded = await deleter.deletedURLs
        #expect(recorded == deleted)
    }

    // MARK: - Adversarial-verifier pins

    @Test func denylistCatchesMiscasedComponentOnCaseInsensitiveVolume() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Library/Developer/Xcode/iOS DeviceSupport/16.0/payload.bin")

        // The denylist defense against mis-cased requests rests entirely on
        // cruftCanonical case-correcting existing components to their
        // on-disk spelling (undocumented Foundation behavior) — this test
        // pins it so a future canonicalization swap can't silently open a
        // case-insensitive-APFS bypass. No-op on case-sensitive volumes.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(
            url: home.url("Library/Developer/Xcode/ios devicesupport/16.0"),
            roots: [home.url("Library/Developer/Xcode")])
        let error = await refusal(deleter, req)
        if case let .denylistedComponent(_, component) = error {
            #expect(component == "iOS DeviceSupport")
        } else {
            Issue.record("expected denylistedComponent, got \(String(describing: error))")
        }
        #expect(home.exists("Library/Developer/Xcode/iOS DeviceSupport/16.0/payload.bin"))
    }

    @Test func homeAsContentsOnlyRootRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        try home.plantFile("Documents/keepme.bin")

        // Rule 1 is STRICTLY under home, so home itself is refused even as
        // a .contentsOnly root with home in allowedRoots — before any child
        // enumeration can happen.
        let deleter = try SafeDeleter(home: home.root, mode: .live)
        let req = request(url: home.root, roots: [home.root], deletionMode: .contentsOnly)
        #expect(await refusal(deleter, req)?.ruleName == "outsideHome")
        #expect(home.exists("Documents/keepme.bin"))
    }
}

private extension SafeDeleterError {
    /// Case name without associated values, for refusal assertions that
    /// only care WHICH rule fired.
    var ruleName: String {
        switch self {
        case .homeOverrideRefused: "homeOverrideRefused"
        case .outsideHome: "outsideHome"
        case .outsideAllowedRoots: "outsideAllowedRoots"
        case .rootItselfRefused: "rootItselfRefused"
        case .denylistedComponent: "denylistedComponent"
        case .depthFloorViolated: "depthFloorViolated"
        case .doesNotExist: "doesNotExist"
        case .notOwnedByCurrentUser: "notOwnedByCurrentUser"
        }
    }
}
