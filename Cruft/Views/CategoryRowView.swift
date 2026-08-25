import CruftKit
import SwiftUI

/// One category row: name (plus a warning badge for non-re-derivable
/// categories), a status badge or spinner while work is in flight, the
/// retained size on the right, and a hover-revealed Clean button — all
/// values come straight from `MenuState.Row`, which owns the display rules.
struct CategoryRowView: View {
    let row: MenuState.Row
    let cleanDisabled: Bool
    let onClean: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.displayName)
                .lineLimit(1)
            if row.isDestructive {
                badge("not re-derivable", color: .orange)
            }
            if !row.supportsCleaning {
                badge("view only", color: .secondary)
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
            if row.supportsCleaning {
                // Always laid out for cleanable rows and revealed on hover,
                // so the row does not shift when the pointer moves over it.
                Button(action: onClean) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(cleanDisabled || !isCleanable)
                .opacity(isHovering && isCleanable ? 1 : 0)
                .accessibilityLabel("Clean \(row.displayName)")
                .help("Clean \(row.displayName)…")
            }
        }
        .font(.callout)
        .help(helpText)
        .onHover { isHovering = $0 }
    }

    private var isBusy: Bool {
        switch row.activity {
        case .discovering, .sizing: return true
        case .idle, .deferred, .failed: return false
        }
    }

    /// A row is cleanable whenever it displays something deletable — even
    /// mid-rescan: the engine's clean() cancels that category's in-flight
    /// walk and SafeDeleter re-validates every path at delete time, so
    /// waiting out a 30-second DerivedData walk buys nothing.
    private var isCleanable: Bool {
        (row.itemCount ?? 0) > 0 || (row.bytes ?? 0) > 0
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
