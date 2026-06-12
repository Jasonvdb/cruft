import Foundation
import Testing
import CruftKit
import CruftKitTestSupport

/// Unit tests for the CLI output/encoding layer (`CLIReportCore`) — the
/// pure functions the cruft-cli run() bodies delegate to. No process is
/// spawned; the integrator exercises the binary end-to-end at the gate.

private let allCategoryIDs = [
    "derived-data", "in-repo-build", "gradle", "swiftpm-cache",
    "xcode-misc", "js-cache", "xcode-archives",
]

/// ByteCountFormatter varies space (regular vs narrow no-break) and unit
/// casing ("KB" vs "kB") across locales; normalize before asserting.
private func normalizedByteString(_ string: String) -> String {
    string
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .replacingOccurrences(of: "\u{202f}", with: " ")
        .lowercased()
}

@Test func jsonOutputMatchesFrozenSchemaExactly() throws {
    let reports = [
        CLICategoryReport(
            id: "derived-data", displayName: "Xcode DerivedData",
            bytes: 12288, itemCount: 2,
            items: [
                CLIItemReport(path: "/tmp/fixture/A", label: "A", bytes: 4096, fileCount: 1),
                CLIItemReport(path: "/tmp/fixture/B", label: "B", bytes: 8192, fileCount: 2),
            ]
        ),
        CLICategoryReport(
            id: "gradle", displayName: "Gradle Caches",
            bytes: 0, itemCount: 0, items: []
        ),
    ]
    let expected = #"{"categories":[{"bytes":12288,"displayName":"Xcode DerivedData","id":"derived-data","itemCount":2,"items":[{"bytes":4096,"fileCount":1,"label":"A","path":"/tmp/fixture/A"},{"bytes":8192,"fileCount":2,"label":"B","path":"/tmp/fixture/B"}]},{"bytes":0,"displayName":"Gradle Caches","id":"gradle","itemCount":0,"items":[]}]}"#
    #expect(try CLIReportCore.jsonOutput(reports) == expected)
}

@Test func byteFormattingUsesFileStyle() {
    #expect(normalizedByteString(CLIReportCore.formattedBytes(4096)) == "4 kb")
    #expect(normalizedByteString(CLIReportCore.formattedBytes(1_000_000_000)) == "1 gb")
    #expect(!CLIReportCore.formattedBytes(0).isEmpty)
}

@Test func scanReportsFollowRegistryOrderWithCanonicalCounts() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }
    try fixture.plantCanonicalFixtureHome()

    let reports = try await CLIReportCore.buildReports(
        sources: SourceRegistry.allSources,
        context: ScanContext(home: fixture.root),
        measurer: FoundationMeasurer()
    )
    #expect(reports.map(\.id) == SourceRegistry.allSources.map { $0.id.rawValue })
    let counts = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0.itemCount) })
    #expect(counts == FixtureHome.canonicalExpectedItemCounts)
    for report in reports {
        #expect(report.items.map(\.path) == report.items.map(\.path).sorted())
        #expect(report.bytes == report.items.reduce(0) { $0 + $1.bytes })
        for item in report.items {
            #expect(item.path.hasPrefix("/"))
            #expect(!item.path.hasSuffix("/"))
        }
    }
}

@Test func missingRootsYieldEmptyCategoriesInRegistryOrder() async throws {
    let fixture = try FixtureHome.makeTemporary()
    defer { try? fixture.destroy() }

    let reports = try await CLIReportCore.buildReports(
        sources: SourceRegistry.allSources,
        context: ScanContext(home: fixture.root),
        measurer: FoundationMeasurer()
    )
    #expect(reports.map(\.id) == allCategoryIDs)
    for report in reports {
        #expect(report.bytes == 0)
        #expect(report.itemCount == 0)
        #expect(report.items.isEmpty)
    }
}

@Test func excludeFilteringRemovesOnlyExcludedAndPreservesOrder() {
    let all = SourceRegistry.allSources
    let filtered = CLIReportCore.filteredSources(
        all, excluding: [CategoryID("derived-data"), CategoryID("js-cache")])
    #expect(filtered.map { $0.id.rawValue }
        == ["in-repo-build", "gradle", "swiftpm-cache", "xcode-misc", "xcode-archives"])
    #expect(CLIReportCore.filteredSources(all, excluding: []).map { $0.id.rawValue }
        == all.map { $0.id.rawValue })
    #expect(CLIReportCore.filteredSources(all, excluding: [CategoryID("bogus")]).count == all.count)
}

@Test func unknownCategoryMessageListsAllSevenIDs() {
    let message = CLIReportCore.unknownCategoryMessage(
        requested: "bogus", sources: SourceRegistry.allSources)
    #expect(message.contains("'bogus'"))
    for id in allCategoryIDs {
        #expect(message.contains(id))
    }
}

@Test func fixturePathGuardAcceptsOnlySystemTempAreas() {
    #expect(CLIReportCore.isAllowedFixturePath(URL(filePath: "/tmp/cruft-fixture-guard-test")))
    #expect(CLIReportCore.isAllowedFixturePath(URL(filePath: "/private/tmp/cruft-fixture-guard-test")))
    #expect(CLIReportCore.isAllowedFixturePath(
        FileManager.default.temporaryDirectory.appending(path: "cruft-fixture-guard-test")))
    #expect(!CLIReportCore.isAllowedFixturePath(URL(filePath: "/Users/nobody/fixture-home")))
    #expect(!CLIReportCore.isAllowedFixturePath(FileManager.default.homeDirectoryForCurrentUser))
    #expect(!CLIReportCore.isAllowedFixturePath(URL(filePath: "/tmp")))
    #expect(!CLIReportCore.isAllowedFixturePath(URL(filePath: "/usr/local/tmp/fixture")))
}

@Test func humanScanTableAlignsColumnsAndEndsWithTotal() {
    let reports = [
        CLICategoryReport(
            id: "derived-data", displayName: "Xcode DerivedData",
            bytes: 12288, itemCount: 2, items: []
        ),
        CLICategoryReport(
            id: "gradle", displayName: "Gradle Caches",
            bytes: 4096, itemCount: 1, items: []
        ),
    ]
    let table = CLIReportCore.humanScanTable(reports)
    let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("Xcode DerivedData"))
    #expect(lines[2].hasPrefix("Total"))
    #expect(lines[2].contains("3"))
    for line in lines {
        #expect(!line.hasSuffix(" "))
        #expect(!line.isEmpty)
    }
    #expect(!table.hasSuffix("\n"))
}

@Test func cleanPlanSummaryListsPathsAndTotal() {
    let summary = CLIReportCore.cleanPlanSummary(
        displayName: "Xcode DerivedData",
        entries: [(path: "/tmp/f/a", bytes: 4096), (path: "/tmp/f/b", bytes: 8192)]
    )
    #expect(summary.contains("Would delete 2 items from Xcode DerivedData:"))
    #expect(summary.contains("/tmp/f/a"))
    #expect(summary.contains("/tmp/f/b"))
    #expect(normalizedByteString(summary).contains("total: 12 kb"))
    #expect(summary.contains("nothing deleted"))

    let empty = CLIReportCore.cleanPlanSummary(displayName: "Gradle Caches", entries: [])
    #expect(empty == "Nothing to clean in Gradle Caches.")
}

@Test func fixtureSummaryPrintsRootThenCountsInRegistryOrder() {
    let summary = CLIReportCore.fixtureSummary(
        root: URL(filePath: "/tmp/cruft-fixture-x/"),
        counts: FixtureHome.canonicalExpectedItemCounts,
        orderedIDs: allCategoryIDs
    )
    let lines = summary.split(separator: "\n").map(String.init)
    #expect(lines.first == "/tmp/cruft-fixture-x")
    #expect(lines.dropFirst().map { String($0.split(separator: ":")[0]) } == allCategoryIDs)
    #expect(lines.contains("derived-data: 3"))
    #expect(lines.contains("xcode-archives: 3"))
}
