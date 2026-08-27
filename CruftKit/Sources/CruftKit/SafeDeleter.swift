import Foundation

/// Why SafeDeleter refused a deletion. Each case maps to one safety rule so
/// tests can assert the exact rule that fired.
public enum SafeDeleterError: Error, Equatable {
    /// Rule 2: the effective home is neither the real canonical $HOME nor a
    /// fixture location under a system temp area (`systemTempAreaPrefixes`).
    case homeOverrideRefused(String)
    /// Rule 1: resolved path escapes the canonical effective home.
    case outsideHome(String)
    /// Rule 3: resolved path is not inside any allowed deletion root.
    case outsideAllowedRoots(String)
    /// Rule 3: the path IS an allowed root and the item is `.entireItem`.
    case rootItselfRefused(String)
    /// Rule 4: a denylisted component appeared in the resolved path.
    case denylistedComponent(String, component: String)
    /// Rule 5: resolved path is fewer than 3 components below home.
    case depthFloorViolated(String)
    /// Rule 7: path does not exist.
    case doesNotExist(String)
    /// Rule 7: not owned by the current user.
    case notOwnedByCurrentUser(String)
    /// Simulator mode: the target, root, metadata, or current state is not an
    /// exact safe match for one registered shutdown simulator.
    case simulatorTargetInvalid(String)
    /// Simulator mode: a booted device must never be deleted.
    case simulatorBooted(String)
    /// Simulator mode: `simctl delete` failed and no deletion is recorded.
    case simulatorDeleteFailed(String)
    /// Guarded-item mode: the exact root, path shape, signature, or retained
    /// metadata did not match the live target.
    case guardedTargetInvalid(String)
    /// Guarded-item mode: the newest metadata change was less than 72 hours
    /// ago, could not be measured, or the walk had errors.
    case minimumAgeNotMet(String)
    /// Guarded-item mode: an open file, working directory, or command line
    /// showed that a process could still be using the target.
    case activeUseDetected(String)
    /// Guarded-item mode: the live-use inspection failed, so deletion stopped
    /// in the safe direction.
    case activeUseCheckFailed(String)
    /// Worktree mode: Git refused or failed the non-force removal.
    case worktreeDeleteFailed(String)
}

/// Injectable command seam for the one real-home simulator mutation.
public protocol SimulatorDeviceCommandRunning: Sendable {
    func deleteSimulator(udid: String) throws
}

public struct SimctlSimulatorDeviceCommandRunner: SimulatorDeviceCommandRunning {
    struct Result: Sendable {
        let status: Int32
        let errorText: String
    }

    enum CommandError: Error, Equatable {
        case failed(Int32, String)
    }

    private let operation: @Sendable (String) throws -> Result

    public init() {
        self.init(processRunner: BoundedDirectProcessRunner())
    }

    init(processRunner: any DirectProcessRunning) {
        self.operation = { udid in
            let result = try processRunner.run(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "delete", udid])
            let rawError = String(
                decoding: result.standardError.prefix(1024), as: UTF8.self)
            let errorText = rawError
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(status: result.status, errorText: errorText)
        }
    }

    init(operation: @escaping @Sendable (String) throws -> Result) {
        self.operation = operation
    }

    public func deleteSimulator(udid: String) throws {
        let result = try operation(udid)
        guard result.status == 0 else {
            throw CommandError.failed(result.status, result.errorText)
        }
    }

}

/// THE deletion choke point. The only file in the repository where
/// file-removal APIs may appear (enforced by Scripts/check-chokepoint.sh in
/// every phase gate and in CI).
///
/// All rules compare canonical paths (`URL.cruftCanonical`) on both sides —
/// never mix canonicalization APIs; see the helper's doc. Denylist wins over
/// allowlist. `.dryRun` runs every check and records the deletion intent
/// without touching the disk.
public actor SafeDeleter: ItemDeleting {
    public enum Mode: Sendable, Equatable {
        case live
        case dryRun
    }

    /// Path components that are never deletable regardless of allowlist.
    /// "Mobile Documents" is iCloud Drive's backing store.
    public static let denylistedComponents: Set<String> = [
        ".git", "Devices", "DeviceSupport", "iOS DeviceSupport",
        "watchOS DeviceSupport", ".avd", "UserData", "Mobile Documents",
    ]

    /// Rule 5: targets sit at least this many components below home.
    /// `home/.npm/_cacache/<child>` is exactly 3 and allowed;
    /// `home/.gradle/caches` as `.entireItem` is 2 and refused.
    private static let depthFloor = 3

    public let mode: Mode
    /// Every URL deleted (live) or validated-as-deletable (dryRun), in order.
    public private(set) var deletedURLs: [URL] = []

    /// Canonical effective home path (trailing slash stripped) — the
    /// right-hand side of every rule-1 and rule-5 comparison.
    private let homePath: String
    private let isRealHome: Bool
    private let simulatorCommandRunner: any SimulatorDeviceCommandRunning
    private let simulatorDeviceTypeNames: any SimulatorDeviceTypeNameProviding
    private let guardedUseChecker: any GuardedArtifactUseChecking
    private let worktreeManager: any AgentWorktreeManaging
    private let measurer: any DirectoryMeasurer
    private let now: @Sendable () -> Date

    /// - Parameter home: canonical effective home (from `ScanContext.home`).
    ///   Throws `homeOverrideRefused` unless it is the real canonical $HOME
    ///   or lives under a system temp area (fixtures).
    public init(
        home: URL,
        mode: Mode,
        simulatorCommandRunner: any SimulatorDeviceCommandRunning =
            SimctlSimulatorDeviceCommandRunner()
    ) throws {
        try self.init(
            home: home,
            mode: mode,
            simulatorCommandRunner: simulatorCommandRunner,
            simulatorDeviceTypeNames: SystemSimulatorDeviceTypeNameProvider(),
            guardedUseChecker: SystemGuardedArtifactUseChecker(),
            worktreeManager: SystemAgentWorktreeManager(),
            measurer: FoundationMeasurer(),
            now: Date.init)
    }

    init(
        home: URL,
        mode: Mode,
        simulatorCommandRunner: any SimulatorDeviceCommandRunning,
        simulatorDeviceTypeNames: any SimulatorDeviceTypeNameProviding,
        guardedUseChecker: any GuardedArtifactUseChecking = SystemGuardedArtifactUseChecker(),
        worktreeManager: any AgentWorktreeManaging = SystemAgentWorktreeManager(),
        measurer: any DirectoryMeasurer = FoundationMeasurer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.mode = mode
        let candidate = Self.normalizedPath(home.cruftCanonical)
        let realHome = Self.normalizedPath(
            FileManager.default.homeDirectoryForCurrentUser.cruftCanonical)
        guard candidate == realHome
            || systemTempAreaPrefixes.contains(where: candidate.hasPrefix)
        else {
            throw SafeDeleterError.homeOverrideRefused(candidate)
        }
        self.homePath = candidate
        self.isRealHome = candidate == realHome
        self.simulatorCommandRunner = simulatorCommandRunner
        self.simulatorDeviceTypeNames = simulatorDeviceTypeNames
        self.guardedUseChecker = guardedUseChecker
        self.worktreeManager = worktreeManager
        self.measurer = measurer
        self.now = now
    }

    @discardableResult
    public func delete(_ request: DeletionRequest) async throws -> [URL] {
        let item = request.item
        let target = try Self.inspect(item.url)
        let targetPath = Self.normalizedPath(target.canonicalURL)

        if item.deletionMode == .temporaryDerivedData {
            return try await deleteTemporaryDerivedData(
                request, target: target, canonicalTargetPath: targetPath)
        }
        try checkInsideHome(targetPath)
        if item.deletionMode == .simulatorDevice {
            return try deleteSimulator(
                request, target: target, canonicalTargetPath: targetPath)
        }
        if item.deletionMode == .agentWorktree {
            return try await deleteAgentWorktree(
                request, target: target, canonicalTargetPath: targetPath)
        }
        try Self.checkDenylist(targetPath)
        try Self.checkAllowedRoots(
            targetPath, roots: request.allowedRoots, mode: item.deletionMode)

        switch item.deletionMode {
        case .entireItem:
            try checkDepthFloor(targetPath)
            try Self.validateOwnership(
                ownerUID: target.ownerUID, currentUID: getuid(), path: targetPath)
            try perform([target.canonicalURL])
            return [target.canonicalURL]
        case .contentsOnly:
            let children = try validatedChildren(of: target.canonicalURL)
            try perform(children)
            return children
        case .simulatorDevice:
            preconditionFailure("simulator deletion returned before the generic switch")
        case .temporaryDerivedData, .agentWorktree:
            preconditionFailure("guarded deletion returned before the generic switch")
        }
    }

    private func deleteTemporaryDerivedData(
        _ request: DeletionRequest,
        target: Inspection,
        canonicalTargetPath: String
    ) async throws -> [URL] {
        let rawTargetPath = Self.normalizedStandardizedPath(request.item.url)
        let parent = request.item.url.deletingLastPathComponent()
        let parentPath = Self.normalizedStandardizedPath(parent)
        guard request.item.categoryID == TemporaryDerivedDataSource.id,
            request.item.deletionMode == .temporaryDerivedData,
            rawTargetPath == canonicalTargetPath,
            target.isDirectory,
            !target.isSymlink,
            request.allowedRoots.count == 1,
            Self.normalizedPath(request.allowedRoots[0].cruftCanonical) == parentPath,
            Self.normalizedStandardizedPath(request.item.url.deletingLastPathComponent()) == parentPath,
            TemporaryDerivedDataValidator.hasXcodeSignature(target.canonicalURL)
        else {
            throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
        }

        if isRealHome {
            let expected = Self.normalizedPath(
                URL(filePath: "/private/tmp", directoryHint: .isDirectory).cruftCanonical)
            guard parentPath == expected else {
                throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
            }
        } else {
            try checkInsideHome(canonicalTargetPath)
            let expected = Self.normalizedPath(
                URL(filePath: homePath, directoryHint: .isDirectory)
                    .appending(path: "private-tmp").cruftCanonical)
            guard parentPath == expected else {
                throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
            }
        }
        try Self.checkDenylist(canonicalTargetPath)
        try Self.validateOwnership(
            ownerUID: target.ownerUID, currentUID: getuid(), path: canonicalTargetPath)
        try await validateMinimumAge(target.canonicalURL)
        try validateNotInUse(target.canonicalURL)

        if mode == .dryRun {
            deletedURLs.append(target.canonicalURL)
            return [target.canonicalURL]
        }
        try perform([target.canonicalURL])
        return [target.canonicalURL]
    }

    private func deleteAgentWorktree(
        _ request: DeletionRequest,
        target: Inspection,
        canonicalTargetPath: String
    ) async throws -> [URL] {
        let rawTargetPath = Self.normalizedStandardizedPath(request.item.url)
        let parent = request.item.url.deletingLastPathComponent()
        let parentPath = Self.normalizedPath(parent.cruftCanonical)
        guard request.item.categoryID == AgentWorktreeSource.id,
            request.item.deletionMode == .agentWorktree,
            rawTargetPath == canonicalTargetPath,
            target.isDirectory,
            !target.isSymlink,
            request.allowedRoots.contains(where: {
                Self.normalizedPath($0.cruftCanonical) == parentPath
            }),
            let retained = request.item.agentWorktreeMetadata,
            retained.isEligibleForDeletion,
            parent.lastPathComponent == "worktrees",
            parent.deletingLastPathComponent().lastPathComponent == ".\(retained.agent.rawValue)"
        else {
            throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
        }
        try Self.checkDenylist(canonicalTargetPath)
        try checkDepthFloor(canonicalTargetPath)
        try Self.validateOwnership(
            ownerUID: target.ownerUID, currentUID: getuid(), path: canonicalTargetPath)

        guard worktreeManager.inspect(
            target: target.canonicalURL,
            repositoryRoot: retained.repositoryRoot,
            agent: retained.agent) == retained
        else {
            throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
        }
        try await validateMinimumAge(target.canonicalURL)
        try validateNotInUse(target.canonicalURL)
        guard worktreeManager.inspect(
            target: target.canonicalURL,
            repositoryRoot: retained.repositoryRoot,
            agent: retained.agent) == retained
        else {
            throw SafeDeleterError.guardedTargetInvalid(rawTargetPath)
        }

        if mode == .dryRun {
            deletedURLs.append(target.canonicalURL)
            return [target.canonicalURL]
        }
        do {
            try worktreeManager.remove(target: target.canonicalURL, metadata: retained)
        } catch {
            throw SafeDeleterError.worktreeDeleteFailed(String(describing: error))
        }
        guard !FileManager.default.fileExists(atPath: canonicalTargetPath) else {
            throw SafeDeleterError.worktreeDeleteFailed("Git reported success but the worktree remains.")
        }
        deletedURLs.append(target.canonicalURL)
        return [target.canonicalURL]
    }

    private func validateMinimumAge(_ target: URL) async throws {
        let size: ItemSize
        do {
            size = try await measurer.measure(target) { _ in }
        } catch {
            throw SafeDeleterError.minimumAgeNotMet(target.path(percentEncoded: false))
        }
        guard GuardedCleanupPolicy.hasCompleteOldMeasurement(size, now: now()) else {
            throw SafeDeleterError.minimumAgeNotMet(target.path(percentEncoded: false))
        }
    }

    private func validateNotInUse(_ target: URL) throws {
        do {
            if try guardedUseChecker.isInUse(target) {
                throw SafeDeleterError.activeUseDetected(target.path(percentEncoded: false))
            }
        } catch let error as SafeDeleterError {
            throw error
        } catch {
            throw SafeDeleterError.activeUseCheckFailed(String(describing: error))
        }
    }

    /// What the rules need to know about one target, gathered with lstat
    /// semantics so a symlink is judged (and deleted) as the link itself.
    private struct Inspection {
        let canonicalURL: URL
        let isSymlink: Bool
        let isDirectory: Bool
        let ownerUID: uid_t?
    }

    /// Rules 6 and 7 groundwork. A symlink leaf keeps its own name and only
    /// the PARENT directory is canonicalized — a link pointing outside home
    /// stays deletable as a link while its target is never validated, and
    /// `FileManager.removeItem` on a link removes the link, not the
    /// destination. Non-links canonicalize fully, so a path routed THROUGH
    /// a symlink is judged at its real location.
    private static func inspect(_ url: URL) throws -> Inspection {
        let rawPath = url.path(percentEncoded: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: rawPath)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.fileReadNoSuchFile.rawValue
        {
            throw SafeDeleterError.doesNotExist(rawPath)
        }
        let isSymlink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        let canonicalURL: URL = isSymlink
            ? url.deletingLastPathComponent().cruftCanonical.appending(path: url.lastPathComponent)
            : url.cruftCanonical
        let ownerUID = (attributes[.ownerAccountID] as? NSNumber).map { uid_t($0.uint32Value) }
        return Inspection(
            canonicalURL: canonicalURL,
            isSymlink: isSymlink,
            isDirectory: isDirectory,
            ownerUID: ownerUID)
    }

    /// Simulator deletion has a narrower contract than ordinary file removal.
    /// It keeps `Devices` denylisted for every other deletion mode and permits
    /// only one direct UUID child of the exact CoreSimulator Devices root.
    private func deleteSimulator(
        _ request: DeletionRequest,
        target: Inspection,
        canonicalTargetPath: String
    ) throws -> [URL] {
        let expectedRoot = URL(filePath: homePath, directoryHint: .isDirectory)
            .appending(path: "Library/Developer/CoreSimulator/Devices")
        let expectedRootPath = Self.normalizedStandardizedPath(expectedRoot)
        let canonicalExpectedRootPath = Self.normalizedPath(expectedRoot.cruftCanonical)
        let rawTargetPath = Self.normalizedStandardizedPath(request.item.url)

        guard canonicalExpectedRootPath == expectedRootPath else {
            throw SafeDeleterError.simulatorTargetInvalid("symlinked root: \(expectedRootPath)")
        }
        guard request.allowedRoots.count == 1,
            Self.normalizedPath(request.allowedRoots[0].cruftCanonical) == expectedRootPath
        else {
            throw SafeDeleterError.simulatorTargetInvalid("wrong allowed root: \(rawTargetPath)")
        }
        guard rawTargetPath == canonicalTargetPath else {
            throw SafeDeleterError.simulatorTargetInvalid("symlinked target: \(rawTargetPath)")
        }
        let rawParentPath = Self.normalizedStandardizedPath(
            request.item.url.deletingLastPathComponent())
        guard rawParentPath == expectedRootPath else {
            throw SafeDeleterError.simulatorTargetInvalid("not a direct child: \(rawTargetPath)")
        }
        guard target.isDirectory, !target.isSymlink else {
            throw SafeDeleterError.simulatorTargetInvalid("not a real directory: \(rawTargetPath)")
        }

        let udid = request.item.url.lastPathComponent
        guard UUID(uuidString: udid) != nil,
            request.item.categoryID == SimulatorDeviceDataSource.id,
            let itemMetadata = request.item.simulatorMetadata,
            UUID(uuidString: itemMetadata.udid) == UUID(uuidString: udid),
            let retainedName = itemMetadata.name,
            itemMetadata.deviceTypeIdentifier != nil,
            itemMetadata.runtimeIdentifier != nil,
            request.item.label == retainedName,
            itemMetadata.isEligibleForDeletion
        else {
            throw SafeDeleterError.simulatorTargetInvalid(rawTargetPath)
        }
        try Self.validateOwnership(
            ownerUID: target.ownerUID, currentUID: getuid(), path: canonicalTargetPath)

        let currentMetadata = SimulatorDeviceMetadataReader().metadata(
            in: target.canonicalURL,
            leafUDID: udid,
            standardNames: simulatorDeviceTypeNames.standardNamesByIdentifier())
        if currentMetadata.isBooted {
            throw SafeDeleterError.simulatorBooted(udid)
        }
        guard currentMetadata.isEligibleForDeletion,
            currentMetadata == itemMetadata,
            currentMetadata.name == request.item.label
        else {
            throw SafeDeleterError.simulatorTargetInvalid(rawTargetPath)
        }

        if mode == .dryRun {
            deletedURLs.append(target.canonicalURL)
            return [target.canonicalURL]
        }
        if isRealHome {
            do {
                try simulatorCommandRunner.deleteSimulator(udid: udid)
            } catch {
                throw SafeDeleterError.simulatorDeleteFailed(String(describing: error))
            }
            deletedURLs.append(target.canonicalURL)
            return [target.canonicalURL]
        }

        // Fixture homes have no CoreSimulator registration. Remove only the
        // exact validated fixture directory through this same choke point.
        try perform([target.canonicalURL])
        return [target.canonicalURL]
    }

    /// Enumerates DIRECT children (hidden files included) of a
    /// `.contentsOnly` root and re-validates each against rules 1, 4, 5 and
    /// 7 independently. All-or-nothing: any refusal aborts before a single
    /// child is touched, so a denylisted child surfaces as
    /// `denylistedComponent` instead of a partial clean.
    private func validatedChildren(of root: URL) throws -> [URL] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .sorted()
        var validated: [URL] = []
        for name in names {
            let child = try Self.inspect(root.appending(path: name))
            let childPath = Self.normalizedPath(child.canonicalURL)
            try checkInsideHome(childPath)
            try Self.checkDenylist(childPath)
            try checkDepthFloor(childPath)
            try Self.validateOwnership(
                ownerUID: child.ownerUID, currentUID: getuid(), path: childPath)
            validated.append(child.canonicalURL)
        }
        return validated
    }

    /// The single point where bytes leave the disk. `.dryRun` records the
    /// same URLs without touching anything.
    private func perform(_ urls: [URL]) throws {
        for url in urls {
            if mode == .live {
                try FileManager.default.removeItem(at: url)
            }
            deletedURLs.append(url)
        }
    }

    /// Rule 1. Strictly under: home itself is never a deletable target.
    private func checkInsideHome(_ canonicalPath: String) throws {
        guard canonicalPath.hasPrefix(homePath + "/") else {
            throw SafeDeleterError.outsideHome(canonicalPath)
        }
    }

    /// Rule 4. Denylist wins over allowlist, so this runs before the
    /// allowed-roots check.
    private static func checkDenylist(_ canonicalPath: String) throws {
        for component in canonicalPath.split(separator: "/") {
            if denylistedComponents.contains(String(component)) {
                throw SafeDeleterError.denylistedComponent(
                    canonicalPath, component: String(component))
            }
        }
    }

    /// Rule 3. Equality with a root is allowed only for `.contentsOnly`,
    /// where the root survives and its direct children are deleted instead.
    private static func checkAllowedRoots(
        _ canonicalPath: String, roots: [URL], mode: DeletionMode
    ) throws {
        let rootPaths = roots.map { normalizedPath($0.cruftCanonical) }
        if rootPaths.contains(canonicalPath) {
            guard mode == .contentsOnly else {
                throw SafeDeleterError.rootItselfRefused(canonicalPath)
            }
            return
        }
        guard rootPaths.contains(where: { canonicalPath.hasPrefix($0 + "/") }) else {
            throw SafeDeleterError.outsideAllowedRoots(canonicalPath)
        }
    }

    /// Rule 5. Only called after `checkInsideHome`, so the relative slice
    /// is well-formed.
    private func checkDepthFloor(_ canonicalPath: String) throws {
        let relative = canonicalPath.dropFirst(homePath.count + 1)
        guard relative.split(separator: "/").count >= Self.depthFloor else {
            throw SafeDeleterError.depthFloorViolated(canonicalPath)
        }
    }

    /// Rule 7 (ownership). Takes injected uids because planting a
    /// foreign-owned fixture requires root: tests drive the refusal branch
    /// directly and the passing branch end-to-end through `delete`.
    static func validateOwnership(ownerUID: uid_t?, currentUID: uid_t, path: String) throws {
        guard let ownerUID, ownerUID == currentUID else {
            throw SafeDeleterError.notOwnedByCurrentUser(path)
        }
    }

    /// Comparable spelling of a canonical URL: percent-decoded path with any
    /// trailing slash stripped, so directory URLs from different APIs agree.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func normalizedStandardizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
