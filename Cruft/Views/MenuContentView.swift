import CruftKit
import SwiftUI

/// The MenuBarExtra window: category rows in registry order, an
/// "updated X ago" footer, and the Clean All / Refresh / Quit row. While a
/// clean awaits confirmation the whole window becomes the confirmation
/// dialog (sheets are unreliable inside `.menuBarExtraStyle(.window)`).
struct MenuContentView: View {
    let model: AppModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pending = model.pendingPlan {
                ConfirmationDialog(
                    pending: pending,
                    onCancel: { model.cancelPendingClean() },
                    onConfirm: { model.confirmPendingClean() }
                )
            } else {
                mainContent
            }
        }
        .padding(12)
        .frame(width: 390)
        .onAppear { model.menuOpened() }
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("cruft")
                .font(.headline)
            Spacer()
            Text(totalText)
                .font(.headline)
                .monospacedDigit()
        }

        Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.menuState.rows) { row in
                    if row.id == SimulatorDeviceDataSource.id {
                        VStack(alignment: .leading, spacing: 6) {
                            CategoryRowView(
                                row: row,
                                cleanDisabled: model.isCleaning,
                                showsCleanAction: false,
                                onClean: {})
                            SimulatorDeviceHierarchyView(
                                hierarchy: model.simulatorHierarchy,
                                cleanDisabled: model.isCleaning,
                                onDelete: { model.requestDeleteSimulatorGroup($0) })
                        }
                    } else if row.id == TemporaryDerivedDataSource.id {
                        guardedCategory(
                            row: row,
                            list: model.temporaryDerivedDataList)
                    } else if row.id == AgentWorktreeSource.id {
                        guardedCategory(
                            row: row,
                            list: model.agentWorktreeList)
                    } else {
                        CategoryRowView(
                            row: row,
                            cleanDisabled: model.isCleaning,
                            showsCleanAction: true,
                            onClean: { model.requestClean(category: row.id) })
                    }
                }
            }
            // Keep row actions clear of the overlaid vertical scroll bar.
            .padding(.trailing, 14)
        }
        // A ScrollView has no useful intrinsic height inside MenuBarExtra.
        // Give it a real viewport or the window can collapse it to zero.
        .frame(height: categoryViewportHeight)

        Divider()

        if let result = model.lastCleanResult {
            CleanResultView(result: result) { model.dismissCleanResult() }
        }
        if model.showsNothingToClean {
            Text("Nothing to clean.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }

        HStack {
            Button("Clean All…") { model.requestCleanAll() }
                .disabled(model.isCleaning)
            if model.isCleaning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Spacer()
            Button("Refresh") { model.refreshNow() }
                .disabled(model.isCleaning)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            Button("Quit") { model.quit() }
        }
        .controlSize(.small)
    }

    private var totalText: String {
        model.menuBarTitle ?? "—"
    }

    private var categoryViewportHeight: CGFloat {
        let categoryRows = CGFloat(model.menuState.rows.count) * 24
        return min(510, max(260, categoryRows + 72))
    }

    private func guardedCategory(
        row: MenuState.Row,
        list: GuardedCleanupList
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CategoryRowView(
                row: row,
                cleanDisabled: model.isCleaning,
                showsCleanAction: false,
                onClean: {})
            GuardedCleanupListView(
                list: list,
                cleanDisabled: model.isCleaning,
                onDelete: { model.requestDeleteGuardedItem($0) })
        }
    }

    private var footerText: String {
        if model.isCleaning {
            return "Cleaning…"
        }
        guard let updated = model.newestDisplayedUpdate else {
            return "Scanning…"
        }
        return "Updated \(Self.friendlyRelative(updated))"
    }

    /// Friendlier than `RelativeDateTimeFormatter`'s raw output: the
    /// sub-minute window is noisy ("22 sec. ago") and, right after a refresh,
    /// a hair of clock skew makes it read "in 0 sec." — collapse all of it to
    /// "just now".
    private static func friendlyRelative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 {
            return "just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
