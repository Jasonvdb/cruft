import ArgumentParser
import CruftKit
import CruftKitTestSupport
import Darwin
import Foundation

extension Clean {
    /// Clean flow, every deletion routed through SafeDeleter:
    /// - default (no `--yes`, or `--dry-run`): validate every item with a
    ///   `.dryRun` SafeDeleter and print what WOULD be deleted plus a total.
    /// - `--yes` with the effective home being the real $HOME: print the
    ///   same summary and require the hidden `--really` flag before any
    ///   bytes leave the disk. Fixture homes need only `--yes`.
    /// - live: statfs free-bytes delta around the deletions is the freed
    ///   number printed (ground truth — APFS clones lie per-file).
    /// Unknown category → EX_USAGE; any SafeDeleterError → stderr, exit 1,
    /// remaining items not attempted.
    func runClean() async throws {
        let scanContext = context.makeContext()
        guard let source = SourceRegistry.source(for: CategoryID(category)) else {
            printToStandardError(CLIReportCore.unknownCategoryMessage(
                requested: category, sources: SourceRegistry.allSources))
            throw ExitCode(EX_USAGE)
        }
        guard source.supportsCleaning else {
            printToStandardError("clean refused: \(source.displayName) is view only.")
            throw ExitCode(EX_USAGE)
        }
        guard source.allowsWholeCategoryCleaning else {
            printToStandardError(
                "clean refused: \(source.displayName) requires an explicit subgroup selection in the app.")
            throw ExitCode(EX_USAGE)
        }

        let items = try await source.discover(context: scanContext)
            .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
        // Sizes are taken BEFORE validation/deletion; per-item allocated
        // bytes only inform the summary, never the freed number.
        let measurer = FoundationMeasurer()
        var entries: [(item: CacheItem, bytes: Int64)] = []
        for item in items {
            let size = (try? await measurer.measure(item.url) { _ in }) ?? ItemSize()
            entries.append((item: item, bytes: size.allocatedBytes))
        }

        if source.isDestructive, let warning = source.destructiveWarning {
            printToStandardError("WARNING: " + warning)
        }

        let live = yes && !dryRun
        guard live else {
            try await validateAndPrintPlan(source: source, context: scanContext, entries: entries)
            return
        }
        guard !isRealHomeDirectory(scanContext.home) || really else {
            try await validateAndPrintPlan(source: source, context: scanContext, entries: entries)
            print("Re-run with --yes --really to delete from your real home directory.")
            return
        }
        try await performLiveClean(source: source, context: scanContext, entries: entries)
    }

    private func validateAndPrintPlan(
        source: any CacheSource,
        context: ScanContext,
        entries: [(item: CacheItem, bytes: Int64)]
    ) async throws {
        do {
            let deleter = try SafeDeleter(home: context.home, mode: .dryRun)
            for entry in entries {
                try await source.clean(item: entry.item, context: context, using: deleter)
            }
        } catch let error as SafeDeleterError {
            printToStandardError("clean refused: \(error)")
            throw ExitCode(1)
        }
        print(CLIReportCore.cleanPlanSummary(
            displayName: source.displayName,
            entries: entries.map { (path: CLIReportCore.normalizedPath($0.item.url), bytes: $0.bytes) }
        ))
    }

    private func performLiveClean(
        source: any CacheSource,
        context: ScanContext,
        entries: [(item: CacheItem, bytes: Int64)]
    ) async throws {
        guard let before = volumeAvailableBytes(at: context.home) else {
            printToStandardError(
                "clean: statfs failed for \(CLIReportCore.normalizedPath(context.home))")
            throw ExitCode(1)
        }
        var deletedItems = 0
        do {
            let deleter = try SafeDeleter(home: context.home, mode: .live)
            for entry in entries {
                try await source.clean(item: entry.item, context: context, using: deleter)
                deletedItems += 1
            }
        } catch let error as SafeDeleterError {
            printToStandardError("clean failed: \(error)")
            throw ExitCode(1)
        }
        let after = volumeAvailableBytes(at: context.home) ?? before
        let freed = max(0, after - before)
        let noun = deletedItems == 1 ? "item" : "items"
        print("Deleted \(deletedItems) \(noun) from \(source.displayName) "
            + "(freed \(CLIReportCore.formattedBytes(freed))).")
    }
}
