import CruftKit
import SwiftUI

/// One category row: name (plus a warning badge for non-re-derivable
/// categories), a status badge or spinner while work is in flight, and the
/// retained size on the right — all values come straight from
/// `MenuState.Row`, which owns the display rules.
struct CategoryRowView: View {
    let row: MenuState.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.displayName)
                .lineLimit(1)
            if row.isDestructive {
                badge("not re-derivable", color: .orange)
            }
            if let status = statusBadge {
                badge(status.text, color: status.color)
            }
            Spacer(minLength: 12)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            if let itemCount = row.itemCount {
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(sizeText)
                .monospacedDigit()
                .foregroundStyle(row.bytes == nil ? .secondary : .primary)
        }
        .font(.callout)
        .help(helpText)
    }

    private var isBusy: Bool {
        switch row.activity {
        case .discovering, .sizing: return true
        case .idle, .deferred, .failed: return false
        }
    }

    private var sizeText: String {
        guard let bytes = row.bytes else {
            return isBusy ? "…" : "—"
        }
        return AppModel.formattedBytes(bytes)
    }

    private var statusBadge: (text: String, color: Color)? {
        switch row.activity {
        case .idle, .discovering, .sizing:
            return nil
        case .deferred(let reason):
            switch reason {
            case .buildActivityDetected: return ("build active", .secondary)
            case .nonLocalVolume: return ("non-local", .secondary)
            case .permissionDenied: return ("no access", .orange)
            case .gatedByPower: return ("deferred", .secondary)
            }
        case .failed:
            return ("failed", .red)
        }
    }

    private var helpText: String {
        switch row.activity {
        case .idle(.some(let updatedAt)):
            return "Last scanned \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
        case .idle(nil):
            return "Not scanned yet"
        case .discovering:
            return "Finding items…"
        case .sizing:
            return "Measuring…"
        case .deferred(let reason):
            switch reason {
            case .buildActivityDetected:
                return "Skipped: a build looks active here right now."
            case .nonLocalVolume:
                return "Skipped: not on a local volume."
            case .permissionDenied:
                return "Skipped: macOS denied access to this location."
            case .gatedByPower:
                return "Skipped: low power or thermal pressure."
            }
        case .failed(let message):
            return "Scan failed: \(message)"
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
