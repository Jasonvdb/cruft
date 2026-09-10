import CruftKit
import SwiftUI

/// One category row: name (plus a warning badge for non-re-derivable
/// categories), a status badge or spinner while work is in flight, the
/// retained size on the right, and a persistent Clean button — all
/// values come straight from `MenuState.Row`, which owns the display rules.
struct CategoryRowView: View {
    let row: MenuState.Row
    let cleanDisabled: Bool
    let showsCleanAction: Bool
    let onClean: () -> Void

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
            if row.supportsCleaning && showsCleanAction {
                Button(action: onClean) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(cleanDisabled || !isCleanable)
                .accessibilityLabel("Clean \(row.displayName)")
                .help("Clean \(row.displayName)…")
            }
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

/// Simulator storage uses two identity sections and runtime subgroups. Only a
/// complete runtime subgroup exposes deletion; parent and identity rows never
/// do. The compact indentation makes the safety boundary visible without
/// adding decorative UI to this menu-bar utility.
struct SimulatorDeviceHierarchyView: View {
    let hierarchy: SimulatorHierarchy
    let cleanDisabled: Bool
    let onDelete: (SimulatorHierarchy.RuntimeGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(hierarchy.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(section.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if section.mainGroup == .other {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("About Other simulators")
                                .help(
                                    "CoreSimulator does not record creator identity. "
                                        + "Other includes Flow and custom-named devices.")
                        }
                    }

                    if section.runtimeGroups.isEmpty {
                        Text("No devices")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                    } else {
                        ForEach(section.runtimeGroups) { group in
                            SimulatorRuntimeRowView(
                                group: group,
                                cleanDisabled: cleanDisabled,
                                onDelete: { onDelete(group) })
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .padding(.leading, 12)
    }
}

/// Collapsed-by-default item list for age-gated cleanup sources. Age only
/// enables the confirmation path. SafeDeleter still performs the live
/// open-file, process, signature, and Git checks after confirmation.
struct GuardedCleanupListView: View {
    let list: GuardedCleanupList
    let cleanDisabled: Bool
    let onDelete: (GuardedCleanupList.Row) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(list.rows) { row in
                    GuardedCleanupItemRow(
                        row: row,
                        cleanDisabled: cleanDisabled,
                        onDelete: { onDelete(row) })
                }
            }
            .padding(.top, 4)
            .padding(.leading, 12)
        } label: {
            Text(reviewLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
    }

    private var reviewLabel: String {
        let count = list.rows.count
        return "Review \(count) \(count == 1 ? "item" : "items")"
    }
}

private struct GuardedCleanupItemRow: View {
    let row: GuardedCleanupList.Row
    let cleanDisabled: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(row.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if let reason = row.blockingReasons.first {
                badge(badgeText(reason), color: badgeColor(reason))
                    .help(helpText(reason))
            } else {
                badge("72h+", color: .secondary)
                    .help("No metadata change was found in the last 72 hours. Live use is checked before deletion.")
            }
            Spacer(minLength: 8)
            Text(AppModel.formattedBytes(row.allocatedBytes))
                .monospacedDigit()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(cleanDisabled || !row.isDeletable)
            .accessibilityLabel("Delete \(row.label)")
            .help(actionHelp)
        }
        .font(.caption)
        .contentShape(Rectangle())
        .help(row.url.path(percentEncoded: false))
    }

    private var actionHelp: String {
        if cleanDisabled { return "Wait for the current deletion to finish." }
        if let reason = row.blockingReasons.first { return helpText(reason) }
        return "Delete after a live active-use safety check…"
    }

    private func badgeText(_ reason: GuardedCleanupList.BlockingReason) -> String {
        switch reason {
        case .recent: "recent"
        case .ageUnknown: "age unknown"
        case .measurementIncomplete: "scan incomplete"
        case .worktreeMetadataUnknown: "Git unknown"
        case .dirty: "dirty"
        case .locked: "locked"
        case .notContainedInPrimaryBranch: "not merged"
        }
    }

    private func badgeColor(_ reason: GuardedCleanupList.BlockingReason) -> Color {
        switch reason {
        case .dirty, .notContainedInPrimaryBranch: .orange
        case .recent, .ageUnknown, .measurementIncomplete,
                .worktreeMetadataUnknown, .locked: .secondary
        }
    }

    private func helpText(_ reason: GuardedCleanupList.BlockingReason) -> String {
        switch reason {
        case .recent:
            "Delete is unavailable because this item changed within the last 72 hours."
        case .ageUnknown:
            "Delete is unavailable because Cruft could not verify the newest change time."
        case .measurementIncomplete:
            "Delete is unavailable because part of the directory could not be measured."
        case .worktreeMetadataUnknown:
            "Delete is unavailable because local Git metadata is incomplete."
        case .dirty:
            "Delete is unavailable because the worktree has uncommitted or untracked files."
        case .locked:
            "Delete is unavailable because Git marks the worktree as locked."
        case .notContainedInPrimaryBranch:
            "Delete is unavailable because the worktree commit is not contained in the local primary branch."
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

private struct SimulatorRuntimeRowView: View {
    let group: SimulatorHierarchy.RuntimeGroup
    let cleanDisabled: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(group.runtimeLabel)
                .lineLimit(1)
            ForEach(group.blockingReasons) { reason in
                badge(reason.badgeText, color: reason.badgeColor)
                    .help(reason.helpText)
            }
            Spacer(minLength: 8)
            Text(deviceCountText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(AppModel.formattedBytes(group.allocatedBytes))
                .monospacedDigit()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(cleanDisabled || !group.isDeletable)
            .accessibilityLabel(
                "Delete \(group.mainGroup.displayName) \(group.runtimeLabel) simulators")
            .help(actionHelp)
        }
        .font(.caption)
        .contentShape(Rectangle())
        .help(rowHelp)
    }

    private var deviceCountText: String {
        "\(group.deviceCount) \(group.deviceCount == 1 ? "device" : "devices")"
    }

    private var actionHelp: String {
        if cleanDisabled { return "Wait for the current deletion to finish." }
        return rowHelp
    }

    private var rowHelp: String {
        if group.blockingReasons.contains(.booted) {
            return "Delete is unavailable because at least one simulator is booted. "
                + "Shut down every simulator in this runtime group."
        }
        if group.blockingReasons.contains(.unknownMetadata) {
            return "Delete is unavailable because simulator metadata is unknown. "
                + "Refresh to scan it again."
        }
        if group.blockingReasons.contains(.notReady) {
            return "Delete is unavailable because at least one simulator is not shut down."
        }
        return "Delete all \(deviceCountText) in "
            + "\(group.mainGroup.displayName) / \(group.runtimeLabel)…"
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

private extension SimulatorHierarchy.DeletionBlockReason {
    var badgeText: String {
        switch self {
        case .booted: "booted"
        case .unknownMetadata: "unknown"
        case .notReady: "not ready"
        }
    }

    var badgeColor: Color {
        switch self {
        case .booted, .notReady: .orange
        case .unknownMetadata: .secondary
        }
    }

    var helpText: String {
        switch self {
        case .booted:
            "At least one simulator is booted. Shut down every simulator in this group."
        case .unknownMetadata:
            "At least one simulator has unknown metadata. Refresh to scan it again."
        case .notReady:
            "At least one simulator is not shut down."
        }
    }
}
