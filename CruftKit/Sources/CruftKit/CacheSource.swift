import Foundation

// =============================================================================
// FROZEN CONTRACTS (v3) — this file is the shared API surface all phases code
// against. Changes require an integrator-approved "contracts vN" bump; never
// edit it from a parallel work branch.
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
    public let mainGroup: MainGroup
    public let runtimeLabel: String
    public let isBooted: Bool
    public let isDeletable: Bool

    public init(
        udid: String,
        mainGroup: MainGroup,
        runtimeLabel: String,
        isBooted: Bool,
        isDeletable: Bool
    ) {
        self.udid = udid
        self.mainGroup = mainGroup
        self.runtimeLabel = runtimeLabel
        self.isBooted = isBooted
        self.isDeletable = isDeletable
    }

    public var hasKnownClassification: Bool {
        mainGroup != .unknown && !runtimeLabel.isEmpty && runtimeLabel != "Unknown"
    }

    /// The shared subgroup, planner, source, and deletion-seam eligibility
    /// rule. SafeDeleter still re-reads device.plist immediately before a
    /// deletion because these retained scan facts can become stale.
    public var isEligibleForDeletion: Bool {
        hasKnownClassification && !isBooted && isDeletable
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

    public init(
        categoryID: CategoryID,
        url: URL,
        label: String,
        deletionMode: DeletionMode = .entireItem,
        simulatorMetadata: SimulatorDeviceMetadata? = nil
    ) {
        self.categoryID = categoryID
        self.url = url
        self.label = label
        self.deletionMode = deletionMode
        self.simulatorMetadata = simulatorMetadata
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

    public init(allocatedBytes: Int64 = 0, fileCount: Int = 0, erroredEntries: Int = 0) {
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.erroredEntries = erroredEntries
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

    public init(item: CacheItem, allowedRoots: [URL]) {
        self.item = item
        self.allowedRoots = allowedRoots
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
}

public extension CacheSource {
    var id: CategoryID { Self.id }
    var includedInCleanAllByDefault: Bool { true }
    var isDestructive: Bool { false }
    var supportsCleaning: Bool { true }
    var allowsWholeCategoryCleaning: Bool { supportsCleaning }
    var destructiveWarning: String? { nil }

    func canClean(item: CacheItem) -> Bool {
        supportsCleaning && item.categoryID == id
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
            DeletionRequest(item: item, allowedRoots: allowedDeletionRoots(context: context))
        )
    }
}

/// A source-level refusal that prevents direct callers from bypassing the
/// planner, UI, or CLI capability checks.
public enum CacheSourceError: Error, Sendable, Equatable {
    case cleaningUnsupported(CategoryID)
    case itemCleaningUnsupported(CategoryID, String)
}
