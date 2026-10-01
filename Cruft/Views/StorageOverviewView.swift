import CruftKit
import SwiftUI

/// "Where did my space go?" for space cruft does not clean. View only: each
/// entry names the action that frees it, and nothing here can delete.
struct StorageOverviewView: View {
    let overview: StorageOverview
    let isMeasuring: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let diskText {
                Text(diskText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if overview.entries.isEmpty {
                        Text(isMeasuring ? "Measuring…" : "Nothing large found.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(overview.entries) { entry in
                        StorageOverviewEntryRow(entry: entry)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 12)
            } label: {
                HStack(spacing: 6) {
                    Text("Other storage")
                        .font(.callout)
                    Text("view only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer(minLength: 8)
                    if isMeasuring {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                    Text(totalText)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(overview.entries.isEmpty ? .secondary : .primary)
                }
            }
            .help("Space that cruft does not clean, and what frees it.")
        }
    }

    private var totalText: String {
        if overview.entries.isEmpty {
            return isMeasuring ? "…" : "—"
        }
        return AppModel.formattedBytes(overview.totalEntryBytes)
    }

    private var diskText: String? {
        guard let total = overview.volumeTotalBytes,
            let available = overview.volumeAvailableBytes
        else { return nil }
        return "Disk: \(AppModel.formattedBytes(available)) free of \(AppModel.formattedBytes(total))"
    }
}

private struct StorageOverviewEntryRow: View {
    let entry: StorageOverview.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(AppModel.formattedBytes(entry.bytes))
                    .monospacedDigit()
            }
            .font(.caption)
            Text(entry.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
