import Foundation

// =============================================================================
// FROZEN CONTRACTS (v7) — this file is the shared API surface all phases code
// against. Changes require an integrator-approved "contracts vN" bump; never
// edit it from a parallel work branch.
//
// v6 adds `AgentWorktreeDeletionPolicy` and the policy-taking eligibility
// method beside it. Both additions are purely additive: no stored property
// changed, so every persisted snapshot from v5 and earlier still decodes.
//
// v7 adds three guarded deletion modes (`testDeviceClone`, `flowRunArtifacts`,
// `simulatorRuntime`), their typed metadata, and the opt-in live-use check on
// `DeletionRequest`. Every new stored property is optional or defaulted, so
// snapshots from v6 and earlier still decode.
// =============================================================================

/// Stable identifier for a cache category. Doubles as the CLI `--category` /
/// `--exclude` value, so raw values are frozen.
public struct CategoryID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public extension URL {
    /// The SINGLE canonicalization used for every path comparison in cruft,
    /// always applied to BOTH sides. Foundation's `resolvingSymlinksInPath()`
    /// resolves symlinks and, on macOS, also strips a leading `/private`
    /// when the result still exists — so `/tmp` and `/private/tmp` converge
    /// to one form. Never mix this with `realpath(3)` (which returns the
    /// `/private`-prefixed form) or prefix checks will silently fail.
    var cruftCanonical: URL { resolvingSymlinksInPath() }
}

/// Path prefixes recognized as system temp areas (fixture homes). Both the
/// `/private`-stripped canonical spellings and the raw ones are listed so
/// guards hold regardless of which API produced the path.
public let systemTempAreaPrefixes: [String] = [
    "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
]

/// Everything a source needs to know about the world it scans.
///
/// `home` and `projectsRoot` are canonicalized via `cruftCanonical` at
/// construction; SafeDeleter compares canonical paths on both sides.
public struct ScanContext: Sendable {
    public let home: URL
    public let projectsRoot: URL
    public let excludedSourceIDs: Set<CategoryID>

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectsRoot: URL? = nil,
        excludedSourceIDs: Set<CategoryID> = []
    ) {
        let canonicalHome = home.cruftCanonical
        self.home = canonicalHome
        self.projectsRoot = (projectsRoot ?? canonicalHome.appending(path: "Documents/Repositories"))
            .cruftCanonical
        self.excludedSourceIDs = excludedSourceIDs
    }
}

/// How a `CacheItem` is deleted.
///
/// - `entireItem`: the item URL itself is removed (e.g. one DerivedData
///   project subdir, one in-repo `build/` dir).
/// - `contentsOnly`: the item URL is a cache root that must survive; its
///   direct children are deleted instead, each individually re-validated by
///   SafeDeleter (e.g. `~/.gradle/caches`).
public enum DeletionMode: String, Sendable, Codable {
    case entireItem
    case contentsOnly
    /// A registered CoreSimulator device. SafeDeleter validates the exact
    /// UUID directory and uses `simctl delete` for a real-home live clean.
    case simulatorDevice
    /// One direct Xcode DerivedData directory under /private/tmp. The
    /// deletion choke point rechecks its signature, age, and active use.
    case temporaryDerivedData
    /// One registered Claude/Codex Git worktree. The deletion choke point
    /// rechecks Git state, age, and active use, then asks Git to remove it.
    /// Force is used only for an uncommitted worktree the user has waived
    /// through `AgentWorktreeDeletionPolicy`, and never more than once — so a
    /// locked worktree stays un-removable.
    case agentWorktree
    /// One registered clone in Xcode's XCTestDevices device set. SafeDeleter
    /// validates the exact UUID directory and uses `simctl --set … delete`.
    case testDeviceClone
    /// One /flow run's artifact directory under /private/tmp/flow-runs. The
    /// choke point rereads the run manifest, applies the age gate unless the
    /// manifest records a terminal state, and checks live use.
    case flowRunArtifacts
    /// One simulator runtime disk image. It lives outside home and is owned by
    /// the system, so SafeDeleter rechecks `simctl` facts and asks `simctl
    /// runtime delete` to remove it. No file is removed directly.
    case simulatorRuntime
}

/// Typed simulator facts retained with a discovered item. CoreSimulator does
/// not record which tool created a device. `other` therefore means a custom
/// name, which can include Flow-created devices, but is not proof of origin.
public struct SimulatorDeviceMetadata: Sendable, Hashable, Codable {
    public enum MainGroup: String, Sendable, Hashable, Codable {
        case xcode
        case other
        case unknown
    }

    public let udid: String
    /// Optional only so snapshots written before contracts v4 still decode.
    /// New simulator discoveries always retain all three exact values.
    public let name: String?
    public let deviceTypeIdentifier: String?
    public let runtimeIdentifier: String?
    public let mainGroup: MainGroup
    public let runtimeLabel: String
    public let isBooted: Bool
    public let isDeletable: Bool

    public init(
        udid: String,
        name: String? = nil,
        deviceTypeIdentifier: String? = nil,
        runtimeIdentifier: String? = nil,
        mainGroup: MainGroup,
        runtimeLabel: String,
        isBooted: Bool,
        isDeletable: Bool
    ) {
        self.udid = udid
        self.name = name
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
        self.mainGroup = mainGroup
        self.runtimeLabel = runtimeLabel
        self.isBooted = isBooted
        self.isDeletable = isDeletable
    }

    public var hasKnownClassification: Bool {
        mainGroup != .unknown && !runtimeLabel.isEmpty && runtimeLabel != "Unknown"
    }

    /// Exact discovery-time identity required for delete-time equality checks.
    /// Older snapshots decode with nil values and remain visible, but they
    /// cannot be deleted until a fresh scan supplies all three facts.
    public var hasExactIdentity: Bool {
        guard let name, let deviceTypeIdentifier, let runtimeIdentifier else {
            return false
        }
        return !name.isEmpty && !deviceTypeIdentifier.isEmpty && !runtimeIdentifier.isEmpty
    }

    /// The shared subgroup, planner, source, and deletion-seam eligibility
    /// rule. SafeDeleter still re-reads device.plist immediately before a
    /// deletion because these retained scan facts can become stale.
    public var isEligibleForDeletion: Bool {
        hasExactIdentity && hasKnownClassification && !isBooted && isDeletable
    }
}

/// How much of a worktree's Git state the user has agreed to give up.
/// `.strict` is the default everywhere and the only value a caller gets
/// without opting in.
///
/// Waiving the two refusals below never waives anything else: the 72-hour
/// age gate, the live active-use check, the locked-worktree refusal, and the
/// registration and Git-identity requirements all still apply. `git worktree
/// remove` leaves the branch ref in place, so an unmerged worktree's commits
/// survive its deletion — uncommitted changes do not.
public struct AgentWorktreeDeletionPolicy: Sendable, Hashable, Codable {
    /// Delete only clean worktrees contained in the local primary branch.
    public static let strict = AgentWorktreeDeletionPolicy(allowsDirtyOrUnmerged: false)
    /// Also delete worktrees with uncommitted work or unmerged commits.
    public static let permissive = AgentWorktreeDeletionPolicy(allowsDirtyOrUnmerged: true)

    public let allowsDirtyOrUnmerged: Bool

    public init(allowsDirtyOrUnmerged: Bool) {
        self.allowsDirtyOrUnmerged = allowsDirtyOrUnmerged
    }
}

/// Typed Git facts retained with a Claude/Codex worktree item. Discovery
/// gathers these from local Git state only. SafeDeleter obtains them again
/// immediately before deletion and requires an exact safe match.
public struct AgentWorktreeMetadata: Sendable, Hashable, Codable {
    public enum Agent: String, Sendable, Hashable, Codable {
        case claude
        case codex

        public var displayName: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
    }

    public let agent: Agent
    public let repositoryRoot: URL
    public let headRevision: String
    public let branchName: String?
    public let primaryReference: String?
    public let isRegistered: Bool
    public let isClean: Bool
    public let isLocked: Bool
    public let isContainedInPrimaryBranch: Bool

    public init(
        agent: Agent,
        repositoryRoot: URL,
        headRevision: String,
        branchName: String? = nil,
        primaryReference: String? = nil,
        isRegistered: Bool,
        isClean: Bool,
        isLocked: Bool,
        isContainedInPrimaryBranch: Bool
    ) {
        self.agent = agent
        self.repositoryRoot = repositoryRoot
        self.headRevision = headRevision
        self.branchName = branchName
        self.primaryReference = primaryReference
        self.isRegistered = isRegistered
        self.isClean = isClean
        self.isLocked = isLocked
        self.isContainedInPrimaryBranch = isContainedInPrimaryBranch
    }

    /// Strict eligibility — the historical rule. Every caller that does not
    /// carry a policy keeps exactly this behaviour.
    public var isEligibleForDeletion: Bool {
        isEligibleForDeletion(policy: .strict)
    }

    /// Eligibility under one policy. Registration, Git identity, and the
    /// locked flag are never negotiable; only "has uncommitted work" and
    /// "not contained in the primary branch" can be waived by the user.
    public func isEligibleForDeletion(policy: AgentWorktreeDeletionPolicy) -> Bool {
        guard isRegistered, !isLocked, !headRevision.isEmpty, primaryReference != nil
        else { return false }
        guard !policy.allowsDirtyOrUnmerged else { return true }
        return isClean && isContainedInPrimaryBranch
    }
}

/// Typed /flow run facts retained with an artifact directory. They come from
/// the run manifest in the flow state directory (`~/.local/state/flow-runs`).
/// A missing manifest is a fact too: such a directory needs the full age gate.
public struct FlowRunMetadata: Sendable, Hashable, Codable {
    /// Manifest states that `flow_run.py` treats as finished.
    public static let terminalStates: Set<String> = [
        "merged", "review_paused", "failed", "timed_out", "cancelled", "abandoned",
    ]
    /// Manifest states that mean a session still owns the run.
    public static let liveStates: Set<String> = ["active", "manual_testing"]

    public let runID: String
    /// The exact manifest state, or nil when no valid manifest exists.
    public let state: String?
    /// The last manifest heartbeat, when the manifest records one.
    public let heartbeatAt: Date?

    public init(runID: String, state: String?, heartbeatAt: Date?) {
        self.runID = runID
        self.state = state
        self.heartbeatAt = heartbeatAt
    }

    public var hasManifest: Bool { state != nil }
    public var isTerminal: Bool { state.map(Self.terminalStates.contains) == true }
    public var isLive: Bool { state.map(Self.liveStates.contains) == true }

    /// The owner said the run is done, so the age gate is not needed. Every
    /// other state keeps the full 72-hour gate.
    public var requiresAgeGate: Bool { !isTerminal }

    /// A live run blocks deletion until its heartbeat is older than the
    /// guarded-cleanup interval. A live run with no heartbeat always blocks.
    public func isActive(now: Date = Date()) -> Bool {
        guard isLive else { return false }
        guard let heartbeatAt else { return true }
        return now.timeIntervalSince(heartbeatAt) < GuardedCleanupPolicy.minimumUntouchedInterval
    }
}

/// Typed `simctl runtime list` facts retained with a runtime disk image.
/// SafeDeleter obtains them again immediately before deletion.
public struct SimulatorRuntimeMetadata: Sendable, Hashable, Codable {
    /// The disk image UUID that `simctl runtime delete` takes.
    public let identifier: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`. Several builds can
    /// share one runtime identifier.
    public let runtimeIdentifier: String
    public let platformName: String
    public let version: String
    public let build: String
    public let state: String
    public let isDeletableBySimctl: Bool
    /// Devices in the default and XCTestDevices sets that use
    /// `runtimeIdentifier`, whatever their build.
    public let deviceCount: Int
    /// The highest installed version for this platform. Kept so Xcode always
    /// has a runtime to run on.
    public let isNewestForPlatform: Bool
    public let lastUsedAt: Date?

    public init(
        identifier: String,
        runtimeIdentifier: String,
        platformName: String,
        version: String,
        build: String,
        state: String,
        isDeletableBySimctl: Bool,
        deviceCount: Int,
        isNewestForPlatform: Bool,
        lastUsedAt: Date?
    ) {
        self.identifier = identifier
        self.runtimeIdentifier = runtimeIdentifier
        self.platformName = platformName
        self.version = version
        self.build = build
        self.state = state
        self.isDeletableBySimctl = isDeletableBySimctl
        self.deviceCount = deviceCount
        self.isNewestForPlatform = isNewestForPlatform
        self.lastUsedAt = lastUsedAt
    }

    public var label: String { "\(platformName) \(version) (\(build))" }
    public var isReady: Bool { state == "Ready" && isDeletableBySimctl }

    public var isEligibleForDeletion: Bool {
        UUID(uuidString: identifier) != nil
            && !runtimeIdentifier.isEmpty
            && isReady
            && deviceCount == 0
            && !isNewestForPlatform
    }

    /// Identity plus every fact that eligibility depends on. `lastUsedAt`
    /// changes on each simulator launch and is not compared.
    public func matchesForDeletion(_ other: SimulatorRuntimeMetadata) -> Bool {
        identifier == other.identifier
            && runtimeIdentifier == other.runtimeIdentifier
            && version == other.version
            && build == other.build
            && isEligibleForDeletion == other.isEligibleForDeletion
    }
}

/// One cleanable thing on disk, discovered by a `CacheSource`. Identity is
/// the category plus the absolute path — never the display label (six repos
/// on the reference machine have an item literally named "build").
public struct CacheItem: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let categoryID: CategoryID
    public let url: URL
    public let label: String
    public let deletionMode: DeletionMode
    /// Present only for simulator-device items. Optional preserves decoding of
    /// v2 persisted snapshots that predate typed simulator metadata.
    public let simulatorMetadata: SimulatorDeviceMetadata?
    /// Present only for Claude/Codex worktrees. Optional preserves decoding
    /// of snapshots written before contracts v5.
    public let agentWorktreeMetadata: AgentWorktreeMetadata?
    /// Present only for /flow run artifacts. Optional since contracts v7.
    public let flowRunMetadata: FlowRunMetadata?
    /// Present only for simulator runtimes. Optional since contracts v7.
    public let simulatorRuntimeMetadata: SimulatorRuntimeMetadata?

    public init(
        categoryID: CategoryID,
        url: URL,
        label: String,
        deletionMode: DeletionMode = .entireItem,
        simulatorMetadata: SimulatorDeviceMetadata? = nil,
        agentWorktreeMetadata: AgentWorktreeMetadata? = nil,
        flowRunMetadata: FlowRunMetadata? = nil,
        simulatorRuntimeMetadata: SimulatorRuntimeMetadata? = nil
    ) {
        self.categoryID = categoryID
        self.url = url
        self.label = label
        self.deletionMode = deletionMode
        self.simulatorMetadata = simulatorMetadata
        self.agentWorktreeMetadata = agentWorktreeMetadata
        self.flowRunMetadata = flowRunMetadata
        self.simulatorRuntimeMetadata = simulatorRuntimeMetadata
        self.id = "\(categoryID.rawValue):\(url.path(percentEncoded: false))"
    }
}

/// Allocated-on-disk measurement of one item. Sizes are ALLOCATED bytes
/// (`totalFileAllocatedSizeKey`), never logical bytes — that is what `du`
/// reports and what deletion actually reclaims.
public struct ItemSize: Sendable, Hashable, Codable {
    public var allocatedBytes: Int64
    public var fileCount: Int
    /// Per-entry enumeration errors that were counted-and-continued
    /// (ENOENT/EACCES on individual entries). A nonzero value marks the
    /// measurement approximate; a root-level failure throws instead.
    public var erroredEntries: Int
    /// Newest metadata modification found anywhere in the measured tree,
    /// including directories. Optional keeps older persisted snapshots valid.
    public var newestModificationDate: Date?

    public init(
        allocatedBytes: Int64 = 0,
        fileCount: Int = 0,
        erroredEntries: Int = 0,
        newestModificationDate: Date? = nil
    ) {
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.erroredEntries = erroredEntries
        self.newestModificationDate = newestModificationDate
    }
}

/// A `CacheItem` with its (possibly still-pending) measurement.
public struct MeasuredItem: Sendable, Hashable, Codable {
    public let item: CacheItem
    public var size: ItemSize?

    public init(item: CacheItem, size: ItemSize? = nil) {
        self.item = item
        self.size = size
    }
}

/// The per-category value the UI renders and StatsStore persists.
public struct CategorySnapshot: Identifiable, Sendable, Codable {
    public let categoryID: CategoryID
    public var items: [MeasuredItem]
    /// Set only when a scan reached `.finished`. Snapshots from cancelled or
    /// error-flagged walks are never persisted.
    public var updatedAt: Date?

    public var id: CategoryID { categoryID }
    public var totalBytes: Int64 { items.reduce(0) { $0 + ($1.size?.allocatedBytes ?? 0) } }
    public var fileCount: Int { items.reduce(0) { $0 + ($1.size?.fileCount ?? 0) } }

    public init(categoryID: CategoryID, items: [MeasuredItem] = [], updatedAt: Date? = nil) {
        self.categoryID = categoryID
        self.items = items
        self.updatedAt = updatedAt
    }
}

/// What initiated a scan. Priority policy is frozen: cruft never runs scan
/// work above `.utility`; scheduled work runs at `.background`, which buys
/// kernel-level disk I/O throttling (IOPOL_THROTTLE) for free.
public enum ScanTrigger: Sendable, Equatable {
    case launch
    case scheduled
    case menuOpened
    case manual
    case postClean

    public var taskPriority: TaskPriority {
        self == .scheduled ? .background : .utility
    }

    /// Max concurrent category walks: the disk is the bottleneck.
    public var width: Int {
        self == .scheduled ? 2 : 3
    }
}

/// Why a category scan did not run.
public enum DeferralReason: Sendable, Equatable {
    /// Root or children modified within the quiet window — likely an active
    /// build; scanning now would contend with it and persist torn numbers.
    case buildActivityDetected
    /// Root lives on a non-local volume; v1 refuses to size those.
    case nonLocalVolume
    /// TCC denied (NSCocoaError 257 / EPERM on the root listing).
    case permissionDenied
    /// ScanGate: low power mode, thermal pressure, or low battery.
    case gatedByPower
}

/// Streamed by ScanEngine to its single consumer (AppModel or the CLI).
public enum ScanEvent: Sendable {
    case categoryStarted(CategoryID)
    case discovered(CategoryID, items: [CacheItem])
    /// Throttled running totals (≤ 4 Hz per category). Presentation rule:
    /// partials drive the primary displayed number only when no prior final
    /// exists — numbers must never visibly shrink during a rescan.
    case partial(CategoryID, CategorySnapshot)
    case finished(CategoryID, CategorySnapshot)
    case deferred(CategoryID, reason: DeferralReason)
    case failed(CategoryID, message: String)
}

/// A validated deletion ask, handed to an `ItemDeleting` implementation.
public struct DeletionRequest: Sendable {
    public let item: CacheItem
    /// Roots the deleter must verify the item against (rule 3). Sources
    /// provide these via `allowedDeletionRoots(context:)`.
    public let allowedRoots: [URL]
    /// When true, the generic modes also refuse a target that an open file,
    /// process working directory, or process command line refers to. Sources
    /// opt in through `CacheSource.requiresLiveUseCheck`.
    public let requiresLiveUseCheck: Bool

    public init(item: CacheItem, allowedRoots: [URL], requiresLiveUseCheck: Bool = false) {
        self.item = item
        self.allowedRoots = allowedRoots
        self.requiresLiveUseCheck = requiresLiveUseCheck
    }
}

/// The deletion seam. `SafeDeleter` is the ONLY production conformer (a CI
/// script enforces that file-removal APIs appear nowhere else); tests use
/// `RecordingDeleter` from CruftKitTestSupport, which is what lets source
/// implementations be developed and tested in parallel with the safety core.
public protocol ItemDeleting: Sendable {
    /// Validates every safety rule and performs (or, in dry-run, records)
    /// the deletion per the item's `DeletionMode`. Returns the URLs deleted
    /// or that would be deleted.
    @discardableResult
    func delete(_ request: DeletionRequest) async throws -> [URL]
}

/// One cache category. Adding a future toolchain (cargo target dirs, …) is
/// one conforming type plus one registry line.
public protocol CacheSource: Sendable {
    /// Frozen raw value; doubles as the CLI category id.
    static var id: CategoryID { get }
    var displayName: String { get }
    /// `false` opts the category out of Clean All unless the user opts in
    /// (Archives). Per-category clean is always available.
    var includedInCleanAllByDefault: Bool { get }
    /// `true` means the contents are NOT re-derivable (Archives hold release
    /// dSYMs) — the UI shows a stronger, explicit warning.
    var isDestructive: Bool { get }
    /// `false` means the category can be scanned and measured, but no clean
    /// path may delete its items.
    var supportsCleaning: Bool { get }
    /// `false` requires an explicit measured-item subset. This prevents broad
    /// category, Clean All, and CLI clean operations while preserving a safe
    /// per-subgroup clean path.
    var allowsWholeCategoryCleaning: Bool { get }
    /// Source-specific warning for data that cannot be re-derived.
    var destructiveWarning: String? { get }
    /// Whether a scheduled scan should defer when the broad scan root was
    /// modified recently. Sources with broad roots and per-item age checks
    /// disable this so unrelated activity does not suppress discovery.
    var defersScheduledScanForRecentRootActivity: Bool { get }
    /// Whether every generic deletion first checks open files, working
    /// directories, and command lines. For caches that a running tool can
    /// execute code from or build into.
    var requiresLiveUseCheck: Bool { get }
    /// Root used for scan safety gates and discovery. This is separate from
    /// deletion roots so a view-only source can declare what it measures
    /// without making that path eligible for deletion.
    func scanRoot(context: ScanContext) -> URL?
    /// Roots every deletion for this category is validated against.
    func allowedDeletionRoots(context: ScanContext) -> [URL]
    /// Fast, sizing-free discovery (existence checks + shallow listings).
    func discover(context: ScanContext) async throws -> [CacheItem]
    /// Deletes one discovered item through the deleter seam.
    @discardableResult
    func clean(item: CacheItem, context: ScanContext, using deleter: any ItemDeleting) async throws -> [URL]
    /// Whether one exact discovered item is eligible for deletion.
    func canClean(item: CacheItem) -> Bool
    /// Whether one exact measured item is eligible for an explicit subset
    /// plan. Age-gated sources use the measurement's newest modification.
    func canClean(measuredItem: MeasuredItem) -> Bool
}

public extension CacheSource {
    var id: CategoryID { Self.id }
    var includedInCleanAllByDefault: Bool { true }
    var isDestructive: Bool { false }
    var supportsCleaning: Bool { true }
    var allowsWholeCategoryCleaning: Bool { supportsCleaning }
    var destructiveWarning: String? { nil }
    var defersScheduledScanForRecentRootActivity: Bool { true }
    var requiresLiveUseCheck: Bool { false }

    func canClean(item: CacheItem) -> Bool {
        supportsCleaning && item.categoryID == id
    }

    func canClean(measuredItem: MeasuredItem) -> Bool {
        canClean(item: measuredItem.item)
    }

    /// Existing cleanable sources scan their first deletion root. Sources
    /// with a different discovery boundary must override this method.
    func scanRoot(context: ScanContext) -> URL? {
        allowedDeletionRoots(context: context).first
    }

    @discardableResult
    func clean(item: CacheItem, context: ScanContext, using deleter: any ItemDeleting) async throws -> [URL] {
        guard supportsCleaning else {
            throw CacheSourceError.cleaningUnsupported(id)
        }
        guard canClean(item: item) else {
            throw CacheSourceError.itemCleaningUnsupported(id, item.id)
        }
        return try await deleter.delete(
            DeletionRequest(
                item: item,
                allowedRoots: allowedDeletionRoots(context: context),
                requiresLiveUseCheck: requiresLiveUseCheck)
        )
    }
}

/// A source-level refusal that prevents direct callers from bypassing the
/// planner, UI, or CLI capability checks.
public enum CacheSourceError: Error, Sendable, Equatable {
    case cleaningUnsupported(CategoryID)
    case itemCleaningUnsupported(CategoryID, String)
}
