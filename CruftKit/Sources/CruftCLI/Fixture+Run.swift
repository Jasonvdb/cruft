import ArgumentParser
import CruftKit
import CruftKitTestSupport
import Darwin
import Foundation

extension Fixture {
    /// Materializes the ONE canonical fixture composition shared with the
    /// conformance suite. Refuses any path outside the system temp areas
    /// (checked after `cruftCanonical`), then prints the canonical root and
    /// the per-category expected item counts in registry order.
    func runFixture() throws {
        let target = URL(filePath: path)
        guard CLIReportCore.isAllowedFixturePath(target) else {
            printToStandardError(
                "fixture: refusing '\(path)' — fixture homes must live under a system temp area "
                    + "(\(systemTempAreaPrefixes.joined(separator: ", ")))")
            throw ExitCode(EX_USAGE)
        }
        let fixture = try FixtureHome(at: target)
        try fixture.plantCanonicalFixtureHome()
        print(CLIReportCore.fixtureSummary(
            root: fixture.root,
            counts: FixtureHome.canonicalExpectedItemCounts,
            orderedIDs: SourceRegistry.allSources.map { $0.id.rawValue }
        ))
    }
}
