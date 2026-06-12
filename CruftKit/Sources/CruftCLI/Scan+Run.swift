import CruftKit
import CruftKitTestSupport
import Foundation

extension Scan {
    /// Drives sources + measurer directly (no ScanEngine dependency — the
    /// CLI has no freshness or persistence needs): registry order minus
    /// `--exclude`, sequential measurement, then one human table or the
    /// frozen JSON document on stdout.
    func runScan() async throws {
        let scanContext = context.makeContext()
        let sources = CLIReportCore.filteredSources(
            SourceRegistry.allSources, excluding: scanContext.excludedSourceIDs)
        let reports = try await CLIReportCore.buildReports(
            sources: sources,
            context: scanContext,
            measurer: FoundationMeasurer(),
            onWarning: { printToStandardError($0) }
        )
        if json {
            print(try CLIReportCore.jsonOutput(reports))
        } else {
            print(CLIReportCore.humanScanTable(reports))
        }
    }
}
