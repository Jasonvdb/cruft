import CruftKit
import SwiftUI

/// Transient line under the rows after a clean finishes: "Freed 5.1 GB —
/// 23 items" (per-category breakdown in the tooltip) or the first error.
/// Dismissible by hand; AppModel also clears it on the next refresh.
struct CleanResultView: View {
    let result: CleanResult
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let error = result.errorMessage {
                Label("Clean failed: \(error)", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else {
                Label(summaryText, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Dismiss")
        }
        .help(breakdownText)
    }

    private var summaryText: String {
        CleanResultSummary.text(
            freedBytes: result.freedBytes,
            deletedItems: result.deletedItems,
            categoryIDs: result.perCategory.map(\.id),
            formattedBytes: AppModel.formattedBytes(result.freedBytes))
    }

    private var breakdownText: String {
        result.perCategory
            .map { "\($0.displayName): \($0.deletedItems) \($0.deletedItems == 1 ? "item" : "items")" }
            .joined(separator: "\n")
    }
}
