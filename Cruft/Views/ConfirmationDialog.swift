import CruftKit
import SwiftUI

/// Confirmation step for a pending clean, rendered in place inside the
/// MenuBarExtra window (a custom in-window dialog — sheets and
/// `.confirmationDialog` attach to a real window and are unreliable inside
/// `.menuBarExtraStyle(.window)`). Everything shown here was precomputed
/// into `PendingCleanConfirmation` by AppModel.
struct ConfirmationDialog: View {
    let pending: PendingCleanConfirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.title)
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                ForEach(pending.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(entry.itemCount) \(entry.itemCount == 1 ? "item" : "items")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text(AppModel.formattedBytes(entry.bytes))
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Estimated total")
                    .font(.callout)
                Spacer()
                Text(AppModel.formattedBytes(pending.estimatedBytes))
                    .font(.callout)
                    .bold()
                    .monospacedDigit()
            }

            if !pending.processWarnings.isEmpty || !pending.destructiveWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Styled by LIST (AppModel builds the two separately),
                    // never by matching warning text: process warnings are
                    // orange, destructive warnings red and bold.
                    ForEach(pending.processWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                    ForEach(pending.destructiveWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.red)
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(deleteButtonTitle)
                        .foregroundStyle(.red)
                }
            }
            .controlSize(.small)
        }
    }

    private var deleteButtonTitle: String {
        let noun = pending.totalItemCount == 1 ? "item" : "items"
        return "Delete \(pending.totalItemCount) \(noun) "
            + "(\(AppModel.formattedBytes(pending.estimatedBytes)))"
    }
}
