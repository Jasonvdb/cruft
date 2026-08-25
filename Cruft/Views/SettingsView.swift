import AppKit
import CruftKit
import ServiceManagement
import SwiftUI

/// The Settings window: projects root, per-category Clean All membership,
/// launch at login, rescan interval. A simple grouped Form — this is a dev
/// tool. Every mutation lands in SettingsStore and then calls
/// `model.applySettingsChange()`, which decides what (if anything) needs
/// rebuilding; Clean All toggles are read live at plan time and rebuild
/// nothing.
struct SettingsView: View {
    let model: AppModel

    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginError: String?

    private var settings: SettingsStore { model.settings }

    /// Per-category row facts, snapshotted from the registry (display name,
    /// default membership, destructiveness never change at runtime).
    private struct CategoryRow: Identifiable {
        let id: CategoryID
        let displayName: String
        /// Destructive or default-out categories get an explicit OPT-IN
        /// toggle; default-in categories get an include/exclude toggle.
        let isOptIn: Bool
        let isDestructive: Bool
    }

    private static let categoryRows: [CategoryRow] = SourceRegistry.allSources
        .filter(\.supportsCleaning)
        .map { source in
            CategoryRow(
                id: source.id,
                displayName: source.displayName,
                isOptIn: source.isDestructive || !source.includedInCleanAllByDefault,
                isDestructive: source.isDestructive)
        }

    var body: some View {
        Form {
            projectsRootSection
            cleanAllSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // LSUIElement app: without activation the settings window opens
            // behind whatever is frontmost.
            NSApp.activate(ignoringOtherApps: true)
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Projects root

    private var projectsRootSection: some View {
        Section {
            LabeledContent("Projects root") {
                Text(model.projectsRootDisplayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(model.projectsRootDisplayPath)
            }
            HStack {
                Button("Choose…") { chooseProjectsRoot() }
                Button("Reset to Default") { setProjectsRoot(nil) }
                    .disabled(settings.projectsRootPath == nil)
            }
        } footer: {
            Text("Scanned for in-repo build folders (build/, .build/, .gradle/). Default: ~/Documents/Repositories.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseProjectsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder scanned for project build outputs."
        panel.directoryURL = URL(
            filePath: model.projectsRootDisplayPath, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProjectsRoot(url.path(percentEncoded: false))
    }

    private func setProjectsRoot(_ path: String?) {
        settings.projectsRootPath = path
        model.applySettingsChange()
    }

    // MARK: - Clean All membership

    private var cleanAllSection: some View {
        Section {
            ForEach(Self.categoryRows) { row in
                Toggle(isOn: cleanAllBinding(for: row)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                        if row.isDestructive {
                            // The destructive warning sits in red right
                            // beside the explicit opt-in toggle.
                            Text(CleanPlanner.destructiveWarning)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        } header: {
            Text("Include in Clean All")
        } footer: {
            Text("Per-category cleaning from the menu is always available regardless of these toggles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cleanAllBinding(for row: CategoryRow) -> Binding<Bool> {
        if row.isOptIn {
            // Explicit opt-in: on = .included, off = back to the default
            // (out). Never silently in.
            Binding(
                get: { settings.membership(of: row.id) == .included },
                set: { settings.setMembership($0 ? .included : .standard, for: row.id) }
            )
        } else {
            // Default-in: on = follow the default, off = explicit exclude.
            Binding(
                get: { settings.membership(of: row.id) != .excluded },
                set: { settings.setMembership($0 ? .standard : .excluded, for: row.id) }
            )
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if LaunchAtLogin.status == .requiresApproval {
                Text("Approval required in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Rescan every \(Int(settings.rescanIntervalHours)) h") {
                Slider(
                    value: rescanIntervalBinding,
                    in: SettingsModel.rescanIntervalRange,
                    step: 1
                )
                .frame(width: 220)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
                // The displayed state is the SMAppService read-back, never
                // the click — registration can be refused or parked on
                // user approval.
                launchAtLoginEnabled = LaunchAtLogin.isEnabled
                settings.launchAtLogin = launchAtLoginEnabled
            }
        )
    }

    private var rescanIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.rescanIntervalHours },
            set: { newValue in
                settings.rescanIntervalHours = newValue
                model.applySettingsChange()
            }
        )
    }
}
