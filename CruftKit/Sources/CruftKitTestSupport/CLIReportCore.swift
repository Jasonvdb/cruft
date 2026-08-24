import CruftKit
import Foundation

/// One item in the frozen `cruft-cli scan --json` schema. Paths are
/// absolute with no trailing slash.
public struct CLIItemReport: Sendable, Equatable, Encodable {
    public let path: String
    public let label: String
    public let bytes: Int64
    public let fileCount: Int

    public init(path: String, label: String, bytes: Int64, fileCount: Int) {
        self.path = path
        self.label = label
        self.bytes = bytes
        self.fileCount = fileCount
    }

    private enum CodingKeys: String, CodingKey {
        case path, label, bytes, fileCount
    }
}

/// One category in the v2 `cruft-cli scan --json` schema. Category
/// order is registry order; `items` are sorted by path.
public struct CLICategoryReport: Sendable, Equatable, Encodable {
    public let id: String
    public let displayName: String
    public let supportsCleaning: Bool
    public let bytes: Int64
    public let itemCount: Int
    public let items: [CLIItemReport]

    public init(
        id: String,
        displayName: String,
        supportsCleaning: Bool,
        bytes: Int64,
        itemCount: Int,
        items: [CLIItemReport]
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsCleaning = supportsCleaning
        self.bytes = bytes
        self.itemCount = itemCount
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, supportsCleaning, bytes, itemCount, items
    }
}

/// Pure output/encoding layer for cruft-cli. It lives in CruftKitTestSupport
/// — which CruftCLI already depends on for the fixture recipes — because
/// SwiftPM cannot import an executable's main module into a test target and
/// the manifest is frozen; this is the one module both the CLI run() bodies
/// and CLIOutputTests can see. Functions here perform no I/O beyond metadata
/// walks driven through the injected `DirectoryMeasurer`.
public enum CLIReportCore {
    /// Registry order minus the excluded ids — the `--exclude` semantics.
    public static func filteredSources(
        _ sources: [any CacheSource], excluding excluded: Set<CategoryID>
    ) -> [any CacheSource] {
        sources.filter { !excluded.contains($0.id) }
    }

    /// Drives discovery + sequential measurement for every source, in the
    /// order given. A missing root yields an empty category (sources return
    /// no items), an unexpected discovery error is reported via `onWarning`
    /// and yields an empty category, and an item whose root vanished between
    /// discovery and measurement is omitted. Items are sorted by path.
    public static func buildReports(
        sources: [any CacheSource],
        context: ScanContext,
        measurer: any DirectoryMeasurer,
        onWarning: @Sendable (String) -> Void = { _ in }
    ) async throws -> [CLICategoryReport] {
        var reports: [CLICategoryReport] = []
        for source in sources {
            var items: [CacheItem] = []
            do {
                items = try await source.discover(context: context)
            } catch {
                onWarning("scan: \(source.id) discovery failed: \(error)")
            }
            var itemReports: [CLIItemReport] = []
            for item in items {
                do {
                    let size = try await measurer.measure(item.url) { _ in }
                    itemReports.append(CLIItemReport(
                        path: normalizedPath(item.url),
                        label: item.label,
                        bytes: size.allocatedBytes,
                        fileCount: size.fileCount
                    ))
                } catch is MeasurementError {
                    continue
                }
            }
            itemReports.sort { $0.path < $1.path }
            reports.append(CLICategoryReport(
                id: source.id.rawValue,
                displayName: source.displayName,
                supportsCleaning: source.supportsCleaning,
                bytes: itemReports.reduce(0) { $0 + $1.bytes },
                itemCount: itemReports.count,
                items: itemReports
            ))
        }
        return reports
    }

    /// The v2 scan JSON document: compact, sorted keys, unescaped
    /// slashes, no trailing newline (the caller's `print` supplies it).
    public static func jsonOutput(_ reports: [CLICategoryReport]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ScanDocument(categories: reports))
        return String(decoding: data, as: UTF8.self)
    }

    /// Aligned human table: displayName, item count, formatted size, then a
    /// total line. No trailing whitespace on any line.
    public static func humanScanTable(_ reports: [CLICategoryReport]) -> String {
        var rows = reports.map { report in
            let name = report.supportsCleaning
                ? report.displayName
                : "\(report.displayName) (view only)"
            return (name: name, count: String(report.itemCount), size: formattedBytes(report.bytes))
        }
        rows.append((
            name: "Total",
            count: String(reports.reduce(0) { $0 + $1.itemCount }),
            size: formattedBytes(reports.reduce(0) { $0 + $1.bytes })
        ))
        let nameWidth = rows.map(\.name.count).max() ?? 0
        let countWidth = rows.map(\.count.count).max() ?? 0
        let sizeWidth = rows.map(\.size.count).max() ?? 0
        return rows
            .map { row in
                padRight(row.name, nameWidth) + "  "
                    + padLeft(row.count, countWidth) + "  "
                    + padLeft(row.size, sizeWidth)
            }
            .joined(separator: "\n")
    }

    /// What `cruft-cli clean` prints in dry-run mode (and as the real-home
    /// `--really` gate summary): every path that would be deleted with its
    /// size, then the total.
    public static func cleanPlanSummary(
        displayName: String, entries: [(path: String, bytes: Int64)]
    ) -> String {
        guard !entries.isEmpty else {
            return "Nothing to clean in \(displayName)."
        }
        let noun = entries.count == 1 ? "item" : "items"
        var lines = ["Would delete \(entries.count) \(noun) from \(displayName):"]
        lines += entries.map { "  \($0.path)  (\(formattedBytes($0.bytes)))" }
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        lines.append("Total: \(formattedBytes(total)) (dry run; nothing deleted)")
        return lines.joined(separator: "\n")
    }

    /// What `cruft-cli fixture` prints: the canonical root path on the first
    /// line, then `id: expected-item-count` per category in the given order.
    public static func fixtureSummary(
        root: URL, counts: [String: Int], orderedIDs: [String]
    ) -> String {
        var lines = [normalizedPath(root)]
        for id in orderedIDs {
            if let count = counts[id] {
                lines.append("\(id): \(count)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Unknown `--category` diagnostic; lists every valid id in registry
    /// order.
    public static func unknownCategoryMessage(
        requested: String, sources: [any CacheSource]
    ) -> String {
        let ids = sources.map { $0.id.rawValue }.joined(separator: ", ")
        return "unknown category '\(requested)'; valid ids: \(ids)"
    }

    /// Fixture homes may only be materialized under a system temp area —
    /// the same guard SafeDeleter and FixtureHome.destroy apply, compared
    /// after `cruftCanonical` so symlinked spellings cannot dodge it.
    public static func isAllowedFixturePath(_ url: URL) -> Bool {
        let canonical = normalizedPath(url.cruftCanonical)
        return systemTempAreaPrefixes.contains { canonical.hasPrefix($0) }
    }

    /// `ByteCountFormatter` `.file` style — what Finder shows and what the
    /// human table and clean summaries print.
    public static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Percent-decoded absolute path with any trailing slash stripped — the
    /// spelling the v2 JSON schema requires.
    public static func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private struct ScanDocument: Encodable {
        let categories: [CLICategoryReport]
    }

    private static func padLeft(_ string: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - string.count)) + string
    }

    private static func padRight(_ string: String, _ width: Int) -> String {
        string + String(repeating: " ", count: max(0, width - string.count))
    }
}
