import Foundation
import Testing
@testable import CruftKit
import CruftKitTestSupport

private let safeSimulatorDeviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
private let safeSimulatorRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
private let safeAlternateDeviceType = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch"
private let safeAlternateRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

private struct SafeSimulatorDeviceTypeNames: SimulatorDeviceTypeNameProviding {
    func standardNamesByIdentifier() -> [String: String] {
        [
            safeSimulatorDeviceType: "iPhone 17 Pro",
            safeAlternateDeviceType: "iPad Pro (13-inch)",
        ]
    }
}

private struct SafeStubDirectProcessRunner: DirectProcessRunning {
    let operation: @Sendable (URL, [String]) throws -> DirectProcessResult

    func run(executable: URL, arguments: [String]) throws -> DirectProcessResult {
        try operation(executable, arguments)
    }
}

/// End-to-end tests for the SafeDeleter choke point. Hermetic: every test
/// plants its own FixtureHome under a system temp area and cleans up
/// exclusively via FixtureHome.destroy().
@Suite struct SafeDeleterTests {
    private func request(
        url: URL, roots: [URL], deletionMode: DeletionMode = .entireItem
    ) -> DeletionRequest {
        let simulatorMetadata: SimulatorDeviceMetadata? = deletionMode == .simulatorDevice
            ? SimulatorDeviceMetadata(
                udid: url.lastPathComponent,
                name: "iPhone 17 Pro",
                deviceTypeIdentifier: safeSimulatorDeviceType,
                runtimeIdentifier: safeSimulatorRuntime,
                mainGroup: .xcode,
                runtimeLabel: "iOS 26.4",
                isBooted: false,
                isDeletable: true)
            : nil
        return DeletionRequest(
            item: CacheItem(
                categoryID: deletionMode == .simulatorDevice
                    ? SimulatorDeviceDataSource.id : CategoryID("test"),
                url: url,
                label: deletionMode == .simulatorDevice ? "iPhone 17 Pro" : url.lastPathComponent,
                deletionMode: deletionMode,
                simulatorMetadata: simulatorMetadata),
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

    private func simulatorDeleter(
        home: URL,
        mode: SafeDeleter.Mode,
        commandRunner: any SimulatorDeviceCommandRunning =
            SimctlSimulatorDeviceCommandRunner()
    ) throws -> SafeDeleter {
        try SafeDeleter(
            home: home,
            mode: mode,
            simulatorCommandRunner: commandRunner,
            simulatorDeviceTypeNames: SafeSimulatorDeviceTypeNames())
    }

    private func overwriteSimulatorState(
        _ state: Any,
        udid: String,
        home: FixtureHome
    ) throws {
        let metadata: [String: Any] = [
            "name": "iPhone 17 Pro",
            "deviceType": safeSimulatorDeviceType,
            "runtime": safeSimulatorRuntime,
            "UDID": udid,
            "state": state,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: home.url(
            "Library/Developer/CoreSimulator/Devices/\(udid)/device.plist"))
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

    // MARK: - Simulator device mode

    @Test func simulatorDryRunValidatesAndRecordsWithoutDeleting() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let udid = "11111111-1111-4111-8111-111111111111"
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: udid,
            name: "iPhone 17 Pro",
            deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime,
            metadataUDID: udid,
            state: 1)
        let device = home.url("Library/Developer/CoreSimulator/Devices/\(udid)")
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .dryRun)

        let deleted = try await deleter.delete(request(
            url: device, roots: [root], deletionMode: .simulatorDevice))

        #expect(deleted.count == 1)
        #expect(home.exists("Library/Developer/CoreSimulator/Devices/\(udid)"))
        #expect(await deleter.deletedURLs == deleted)
    }

    @Test func simulatorFixtureLiveDeletesOnlyExactDeviceDirectory() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let udid = "22222222-2222-4222-8222-222222222222"
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: udid,
            name: "iPhone 17 Pro",
            deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime,
            metadataUDID: udid,
            state: 1)
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .live)

        _ = try await deleter.delete(request(
            url: root.appending(path: udid), roots: [root], deletionMode: .simulatorDevice))

        #expect(!home.exists("Library/Developer/CoreSimulator/Devices/\(udid)"))
        #expect(home.exists("Library/Developer/CoreSimulator/Devices"))
    }

    @Test func simulatorBootedAndMismatchedMetadataAreRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let booted = "33333333-3333-4333-8333-333333333333"
        let mismatch = "44444444-4444-4444-8444-444444444444"
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: booted, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: booted, state: 3)
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: mismatch, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: booted, state: 1)
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .live)

        #expect(await refusal(deleter, request(
            url: root.appending(path: booted), roots: [root],
            deletionMode: .simulatorDevice))?.ruleName == "simulatorBooted")
        #expect(await refusal(deleter, request(
            url: root.appending(path: mismatch), roots: [root],
            deletionMode: .simulatorDevice))?.ruleName == "simulatorTargetInvalid")
        #expect(home.exists("Library/Developer/CoreSimulator/Devices/\(booted)"))
        #expect(home.exists("Library/Developer/CoreSimulator/Devices/\(mismatch)"))
    }

    @Test func simulatorBooleanAndFloatingStatesAreRefusedAtDeletionSeam() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let booleanState = "BBBBBBB1-BBBB-4BBB-8BBB-BBBBBBBBBBB1"
        let floatingState = "BBBBBBB2-BBBB-4BBB-8BBB-BBBBBBBBBBB2"
        for udid in [booleanState, floatingState] {
            _ = try home.plantSimulatorDeviceDecoy(uuid: udid)
        }
        try overwriteSimulatorState(true, udid: booleanState, home: home)
        try overwriteSimulatorState(1.5, udid: floatingState, home: home)
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .dryRun)

        for udid in [booleanState, floatingState] {
            #expect(await refusal(deleter, request(
                url: root.appending(path: udid), roots: [root],
                deletionMode: .simulatorDevice))?.ruleName == "simulatorTargetInvalid")
            #expect(home.exists("Library/Developer/CoreSimulator/Devices/\(udid)"))
        }
        #expect(await deleter.deletedURLs.isEmpty)
    }

    @Test func simulatorChangedIdentityFactsAndRetainedLabelAreRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let renamed = "AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAA1"
        let changedType = "AAAAAAA2-AAAA-4AAA-8AAA-AAAAAAAAAAA2"
        let changedRuntime = "AAAAAAA3-AAAA-4AAA-8AAA-AAAAAAAAAAA3"
        let staleLabel = "AAAAAAA4-AAAA-4AAA-8AAA-AAAAAAAAAAA4"
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: renamed, name: "Renamed", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: renamed, state: 1)
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: changedType, name: "iPhone 17 Pro", deviceType: safeAlternateDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: changedType, state: 1)
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: changedRuntime, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeAlternateRuntime, metadataUDID: changedRuntime, state: 1)
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: staleLabel, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: staleLabel, state: 1)
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .dryRun)

        for udid in [renamed, changedType, changedRuntime] {
            #expect(await refusal(deleter, request(
                url: root.appending(path: udid), roots: [root],
                deletionMode: .simulatorDevice))?.ruleName == "simulatorTargetInvalid")
        }
        let retained = request(
            url: root.appending(path: staleLabel), roots: [root],
            deletionMode: .simulatorDevice)
        let wrongLabel = DeletionRequest(
            item: CacheItem(
                categoryID: retained.item.categoryID,
                url: retained.item.url,
                label: "Stale label",
                deletionMode: retained.item.deletionMode,
                simulatorMetadata: retained.item.simulatorMetadata),
            allowedRoots: retained.allowedRoots)
        #expect(await refusal(deleter, wrongLabel)?.ruleName == "simulatorTargetInvalid")
        #expect(await deleter.deletedURLs.isEmpty)
    }

    @Test func simulatorRootNestedSymlinkAndOrdinaryModesAreRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        defer { try? home.destroy() }
        let direct = "55555555-5555-4555-8555-555555555555"
        let nested = "66666666-6666-4666-8666-666666666666"
        let linked = "77777777-7777-4777-8777-777777777777"
        _ = try home.plantSimulatorDeviceDecoy(
            uuid: direct, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: direct, state: 1)
        try home.plantFile(
            "Library/Developer/CoreSimulator/Devices/\(direct)/nested/\(nested)/payload.bin")
        let linkedTarget = try home.plantDir("Library/Caches/simulator-link-target")
        try home.plantSymlink(
            at: "Library/Developer/CoreSimulator/Devices/\(linked)",
            to: linkedTarget.path(percentEncoded: false))
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .live)

        #expect(await refusal(deleter, request(
            url: root, roots: [root], deletionMode: .simulatorDevice))?.ruleName
            == "simulatorTargetInvalid")
        #expect(await refusal(deleter, request(
            url: root.appending(path: "\(direct)/nested/\(nested)"), roots: [root],
            deletionMode: .simulatorDevice))?.ruleName == "simulatorTargetInvalid")
        #expect(await refusal(deleter, request(
            url: root.appending(path: linked), roots: [root],
            deletionMode: .simulatorDevice))?.ruleName == "simulatorTargetInvalid")
        #expect(await refusal(deleter, request(
            url: root.appending(path: direct), roots: [root],
            deletionMode: .entireItem))?.ruleName == "denylistedComponent")
        #expect(home.exists("Library/Developer/CoreSimulator/Devices/\(direct)"))
        #expect(home.exists("Library/Caches/simulator-link-target"))
    }

    @Test func simulatorIntermediateRootSymlinkIsRefused() async throws {
        let home = try FixtureHome.makeTemporary()
        let outside = try FixtureHome.makeTemporary()
        defer {
            try? home.destroy()
            try? outside.destroy()
        }
        let udid = "88888888-8888-4888-8888-888888888888"
        _ = try outside.plantSimulatorDeviceDecoy(
            uuid: udid, name: "iPhone 17 Pro", deviceType: safeSimulatorDeviceType,
            runtime: safeSimulatorRuntime, metadataUDID: udid, state: 1)
        try home.plantDir("Library/Developer")
        try home.plantSymlink(
            at: "Library/Developer/CoreSimulator",
            to: outside.url("Library/Developer/CoreSimulator").path(percentEncoded: false))
        let root = home.url("Library/Developer/CoreSimulator/Devices")
        let deleter = try simulatorDeleter(home: home.root, mode: .live)

        #expect(await refusal(deleter, request(
            url: root.appending(path: udid), roots: [root],
            deletionMode: .simulatorDevice))?.ruleName == "outsideHome")
        #expect(outside.exists("Library/Developer/CoreSimulator/Devices/\(udid)"))
    }

    @Test func simctlCommandFailureSeamReportsNonzeroExit() throws {
        let runner = SimctlSimulatorDeviceCommandRunner { udid in
            #expect(udid == "99999999-9999-4999-8999-999999999999")
            return .init(status: 72, errorText: "simulated failure")
        }

        #expect(throws: SimctlSimulatorDeviceCommandRunner.CommandError.failed(
            72, "simulated failure")) {
            try runner.deleteSimulator(udid: "99999999-9999-4999-8999-999999999999")
        }
    }

    @Test func simctlDeleteTimeoutIsTypedAndUsesDirectArguments() {
        let processRunner = SafeStubDirectProcessRunner { executable, arguments in
            #expect(executable == URL(filePath: "/usr/bin/xcrun"))
            #expect(arguments == [
                "simctl", "delete", "99999999-9999-4999-8999-999999999999",
            ])
            throw DirectProcessError.timedOut(
                executable: executable.path(percentEncoded: false), seconds: 0.01)
        }
        let runner = SimctlSimulatorDeviceCommandRunner(processRunner: processRunner)

        #expect(throws: DirectProcessError.timedOut(
            executable: "/usr/bin/xcrun", seconds: 0.01)) {
            try runner.deleteSimulator(udid: "99999999-9999-4999-8999-999999999999")
        }
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
        case .simulatorTargetInvalid: "simulatorTargetInvalid"
        case .simulatorBooted: "simulatorBooted"
        case .simulatorDeleteFailed: "simulatorDeleteFailed"
        }
    }
}
