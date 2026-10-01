import Foundation

/// /flow run artifact directories: `/private/tmp/flow-runs/<run-id>`. Each
/// run registers a manifest at `~/.local/state/flow-runs/<run-id>.json`. A
/// manifest in a terminal state is the owner's statement that the run is
/// done, so such a directory needs no age gate. Every other directory keeps
/// the full guarded-cleanup rules. Cleanup is explicit per item.
public struct FlowRunArtifactSource: CacheSource {
    public static let id = CategoryID("flow-run-artifacts")
    public let displayName = "Flow Run Artifacts"
    public let includedInCleanAllByDefault = false
    public let allowsWholeCategoryCleaning = false
    public let defersScheduledScanForRecentRootActivity = false

    public init() {}

    public func scanRoot(context: ScanContext) -> URL? {
        Self.artifactRoot(context: context)
    }

    public func allowedDeletionRoots(context: ScanContext) -> [URL] {
        [Self.artifactRoot(context: context)]
    }

    public func canClean(item: CacheItem) -> Bool {
        item.categoryID == Self.id
            && item.deletionMode == .flowRunArtifacts
            && item.flowRunMetadata != nil
    }

    public func canClean(measuredItem: MeasuredItem) -> Bool {
        canClean(item: measuredItem.item)
            && GuardedCleanupList.blockingReasons(for: measuredItem).isEmpty
    }

    public func discover(context: ScanContext) async throws -> [CacheItem] {
        let root = Self.artifactRoot(context: context)
        guard TemporaryDerivedDataValidator.isRealDirectory(root) else { return [] }
        let reader = FlowRunManifestReader(
            stateDirectory: Self.stateDirectory(context: context))

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return entries.compactMap { listed in
            let name = listed.lastPathComponent
            let listedCandidate = root.appending(path: name)
            guard FlowRunManifestReader.isValidRunID(name),
                TemporaryDerivedDataValidator.isRealDirectory(listedCandidate)
            else { return nil }
            // Same spelling rule as temporary DerivedData: validate through
            // the physical path, retain the canonical one.
            let candidate = listedCandidate.cruftCanonical
            return CacheItem(
                categoryID: Self.id,
                url: candidate,
                label: name,
                deletionMode: .flowRunArtifacts,
                flowRunMetadata: reader.metadata(runID: name))
        }
        .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    /// Fixture runs never touch the Mac's shared /private/tmp. They use a
    /// stand-in below the fixture home, beside temporary DerivedData's.
    static func artifactRoot(context: ScanContext) -> URL {
        if isRealHome(context.home) {
            return URL(filePath: "/private/tmp/flow-runs", directoryHint: .isDirectory)
        }
        return context.home.appending(path: "private-tmp/flow-runs")
    }

    /// `flow_run.py`'s default state directory. A run that moved its state
    /// elsewhere has no manifest here and keeps the full age gate.
    static func stateDirectory(context: ScanContext) -> URL {
        context.home.appending(path: ".local/state/flow-runs")
    }

    static func isRealHome(_ home: URL) -> Bool {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.cruftCanonical
        return normalizedPath(home) == normalizedPath(realHome)
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.cruftCanonical.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// One strict manifest parser shared by discovery and the deletion choke
/// point. Anything unexpected reads as "no manifest", which keeps the age
/// gate in force — never as a terminal state.
struct FlowRunManifestReader: Sendable {
    private static let maximumManifestBytes = 1024 * 1024
    private static let maximumRunIDLength = 200

    let stateDirectory: URL

    /// `flow_run.py` accepts only letters, digits, `-`, and `_`.
    static func isValidRunID(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maximumRunIDLength,
            let first = name.unicodeScalars.first,
            CharacterSet.alphanumerics.contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    func metadata(runID: String) -> FlowRunMetadata {
        let missing = FlowRunMetadata(runID: runID, state: nil, heartbeatAt: nil)
        guard Self.isValidRunID(runID) else { return missing }
        let manifest = stateDirectory.appending(path: "\(runID).json")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? manifest.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size <= Self.maximumManifestBytes,
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Self.isSchemaVersionOne(dictionary["schemaVersion"]),
            dictionary["runId"] as? String == runID,
            let state = dictionary["state"] as? String,
            !state.isEmpty, state.count <= 64
        else { return missing }

        let heartbeat = (dictionary["heartbeatAt"] as? String).flatMap(Self.parseDate)
        return FlowRunMetadata(runID: runID, state: state, heartbeatAt: heartbeat)
    }

    /// JSON Booleans also bridge to NSNumber; accept only the integer 1.
    private static func isSchemaVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else { return false }
        return number.intValue == 1
    }

    /// `flow_run.py` writes `2026-10-01T06:22:11+00:00`.
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
