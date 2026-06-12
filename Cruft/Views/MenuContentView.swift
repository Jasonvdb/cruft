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
        .frame(width: 340)
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

        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.menuState.rows) { row in
                CategoryRowView(
                    row: row,
                    cleanDisabled: model.isCleaning,
                    onClean: { model.requestClean(category: row.id) }
                )
            }
        }

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

    private var footerText: String {
        if model.isCleaning {
            return "Cleaning…"
        }
        guard let updated = model.newestDisplayedUpdate else {
            return "Scanning…"
        }
        let relative = Self.relativeFormatter.localizedString(for: updated, relativeTo: Date())
        return "Updated \(relative)"
    }
}
