import CruftKit
import SwiftUI

/// The MenuBarExtra window: category rows in registry order, an
/// "updated X ago" footer, and the Refresh / Clean (Phase 5) / Quit row.
struct MenuContentView: View {
    let model: AppModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    CategoryRowView(row: row)
                }
            }

            Divider()

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                // Phase 5 wires cleaning; the affordance ships disabled so
                // the layout is final before any deletion path exists.
                Button("Clean…") {}
                    .disabled(true)
                    .help("Cleaning arrives in a later build.")
                Spacer()
                Button("Refresh") { model.refreshNow() }
                Button("Quit") { model.quit() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.menuOpened() }
    }

    private var totalText: String {
        model.menuBarTitle ?? "—"
    }

    private var footerText: String {
        guard let updated = model.newestDisplayedUpdate else {
            return "Scanning…"
        }
        let relative = Self.relativeFormatter.localizedString(for: updated, relativeTo: Date())
        return "Updated \(relative)"
    }
}
