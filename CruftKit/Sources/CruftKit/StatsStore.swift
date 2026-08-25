import Foundation

/// Persisted last-known sizes so the menu paints real numbers with
/// "updated X ago" in the first frame of every launch.
///
/// Invariants (frozen):
/// - This actor is the ONLY writer of stats.json; writes are coalesced and
///   atomic.
/// - Items are keyed by full absolute path (display names collide — six
///   repos on the reference machine have an item named "build").
/// - Dates encode as ISO-8601.
/// - Only snapshots that reached `.finished` are ever stored; cancelled or
///   error-flagged walks keep the previous record (an older `updatedAt` is
///   the truthful state).
/// - Unknown `schemaVersion` or decode failure: reset the file and fall
///   through to the first-launch flow. Never crash, never half-decode.
///   (File-removal APIs live only in SafeDeleter, so "reset" atomically
///   overwrites stats.json with an empty valid `PersistedStats` instead of
///   deleting it — same first-launch outcome.)
public actor StatsStore {
    public static let currentSchemaVersion = 1

    /// In-memory identity of one accepted snapshot update. Tokens are not
    /// persisted; they only let a suspended scan compare-and-invalidate its
    /// own write without removing a later clean remainder or scan result.
    public struct SnapshotUpdateToken: Sendable, Hashable {
        fileprivate let categoryID: CategoryID
        fileprivate let identity: UUID
    }

    public struct PersistedStats: Sendable, Codable {
        public var schemaVersion: Int
        public var categories: [String: CategorySnapshot]

        public init(schemaVersion: Int = StatsStore.currentSchemaVersion,
                    categories: [String: CategorySnapshot] = [:]) {
            self.schemaVersion = schemaVersion
            self.categories = categories
        }
    }

    private let fileURL: URL
    /// Coalescing window between `update` and the disk write.
    private let debounceInterval: Duration

    private var categories: [String: CategorySnapshot] = [:]
    private var updateTokens: [String: SnapshotUpdateToken] = [:]
    private var pendingWrite: Task<Void, Never>?

    /// `~/Library/Application Support/Cruft/stats.json`
    public static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cruft/stats.json")
    }

    public init(fileURL: URL = StatsStore.defaultFileURL()) {
        self.init(fileURL: fileURL, debounceInterval: .milliseconds(500))
    }

    /// Test hook: a short debounce makes coalescing observable without
    /// slowing the suite.
    init(fileURL: URL, debounceInterval: Duration) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
    }

    /// Decodes stats.json into memory and returns the stored snapshots
    /// (sorted by category id for determinism). A missing file is the
    /// first-launch case; a corrupt or wrong-schema file is reset to an
    /// empty valid file and treated the same.
    public func load() -> [CategorySnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else {
            categories = [:]
            updateTokens = [:]
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stats = try? decoder.decode(PersistedStats.self, from: data),
            stats.schemaVersion == Self.currentSchemaVersion
        else {
            categories = [:]
            updateTokens = [:]
            writeNow()
            return []
        }
        categories = stats.categories
        updateTokens = Dictionary(uniqueKeysWithValues: categories.keys.map { key in
            let category = CategoryID(key)
            return (key, SnapshotUpdateToken(categoryID: category, identity: UUID()))
        })
        return categories.values.sorted { $0.categoryID.rawValue < $1.categoryID.rawValue }
    }

    /// Merges one FINISHED snapshot and schedules a coalesced write.
    /// Snapshots without `updatedAt` never reached `.finished` and are
    /// ignored — the previous record stays the truthful state.
    @discardableResult
    public func update(_ snapshot: CategorySnapshot) -> SnapshotUpdateToken? {
        guard snapshot.updatedAt != nil else { return nil }
        let key = snapshot.categoryID.rawValue
        let token = SnapshotUpdateToken(
            categoryID: snapshot.categoryID,
            identity: UUID())
        categories[key] = snapshot
        updateTokens[key] = token
        scheduleWrite()
        return token
    }

    /// Compensating write after a clean: drops deleted items from the
    /// stored snapshot, zeroes `.contentsOnly` roots whose children were
    /// deleted, and stamps the result as fresh truth — so quitting before
    /// the post-clean rescan finishes cannot repaint pre-clean numbers on
    /// the next launch. Paths are compared with trailing slashes stripped
    /// (SafeDeleter's returned directory URLs may carry one).
    public func noteCleaned(category: CategoryID, deletedPaths: [String]) {
        let deleted = Set(deletedPaths.map(Self.normalized))
        var snapshot = categories[category.rawValue]
            ?? CategorySnapshot(categoryID: category)
        snapshot.items = snapshot.items.compactMap { measured in
            let path = Self.normalized(measured.item.url.path(percentEncoded: false))
            if deleted.contains(path) { return nil }
            if deleted.contains(where: { $0.hasPrefix(path + "/") }) {
                var zeroed = measured
                zeroed.size = ItemSize()
                return zeroed
            }
            return measured
        }
        snapshot.updatedAt = Date()
        let key = category.rawValue
        categories[key] = snapshot
        updateTokens[key] = SnapshotUpdateToken(categoryID: category, identity: UUID())
        scheduleWrite()
    }

    /// A walker persisted a snapshot that a concurrent clean immediately
    /// invalidated: drop the category's record entirely so the next launch
    /// rescans instead of trusting either version.
    public func invalidate(category: CategoryID) {
        categories.removeValue(forKey: category.rawValue)
        updateTokens.removeValue(forKey: category.rawValue)
        scheduleWrite()
    }

    /// Removes a category only when `token` still identifies its current
    /// in-memory snapshot. A newer `update` or `noteCleaned` replaces the
    /// token, so an older suspended scan cannot invalidate newer truth.
    @discardableResult
    public func invalidate(
        category: CategoryID,
        ifCurrent token: SnapshotUpdateToken
    ) -> Bool {
        let key = category.rawValue
        guard token.categoryID == category,
            updateTokens[key] == token
        else {
            return false
        }
        categories.removeValue(forKey: key)
        updateTokens.removeValue(forKey: key)
        scheduleWrite()
        return true
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Flush any coalesced write to disk now (quit path).
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            self.completePendingWrite()
        }
    }

    private func completePendingWrite() {
        pendingWrite = nil
        writeNow()
    }

    /// Atomic write of the in-memory state. Best-effort: stats are a cache
    /// of re-derivable numbers, so a failed write degrades to a stale file
    /// rather than an error path.
    private func writeNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(PersistedStats(categories: categories)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
