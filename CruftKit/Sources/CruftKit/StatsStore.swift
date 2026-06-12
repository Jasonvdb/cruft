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
/// - Unknown `schemaVersion` or decode failure: delete the file and fall
///   through to the first-launch flow. Never crash, never half-decode.
public actor StatsStore {
    public static let currentSchemaVersion = 1

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

    /// `~/Library/Application Support/Cruft/stats.json`
    public static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cruft/stats.json")
    }

    public init(fileURL: URL = StatsStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() -> [CategorySnapshot] {
        fatalError("StatsStore.load not implemented (Phase 3)")
    }

    public func update(_ snapshot: CategorySnapshot) {
        fatalError("StatsStore.update not implemented (Phase 3)")
    }

    /// Flush any coalesced write to disk now (quit path).
    public func flush() {
        fatalError("StatsStore.flush not implemented (Phase 3)")
    }
}
