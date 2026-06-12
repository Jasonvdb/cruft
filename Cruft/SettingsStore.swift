import CruftKit
import Foundation
import Observation

/// The app's settings: a thin, observable UserDefaults binding around
/// CruftKit's pure `SettingsModel` (which owns clamping and the Clean All
/// set algebra). Plain primitives only — String?, [String], Bool, Double.
///
/// CRUFT_HOME runs (fixture testing) get an EPHEMERAL in-memory model
/// instead of UserDefaults, so harness launches never read or pollute the
/// real preferences domain.
@Observable @MainActor
final class SettingsStore {
    private enum Keys {
        static let projectsRootPath = "projectsRootPath"
        static let cleanAllIncluded = "cleanAllIncluded"
        static let cleanAllExcluded = "cleanAllExcluded"
        static let launchAtLogin = "launchAtLogin"
        static let rescanIntervalHours = "rescanIntervalHours"
    }

    /// nil = ephemeral (CRUFT_HOME fixture run): mutations stay in memory.
    private let defaults: UserDefaults?
    private(set) var model: SettingsModel

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if environment["CRUFT_HOME"] != nil {
            self.defaults = nil
            var model = SettingsModel()
            // Debug hook (gate observability): set the projects root at
            // launch without scripting the Settings UI. Fixture runs only —
            // it flows through the exact code path the folder picker uses.
            if let debugRoot = environment["CRUFT_DEBUG_PROJECTS_ROOT"] {
                model.projectsRootPath = debugRoot
            }
            self.model = model
        } else {
            let defaults = UserDefaults.standard
            self.defaults = defaults
            self.model = SettingsModel(
                projectsRootPath: defaults.string(forKey: Keys.projectsRootPath),
                cleanAllIncluded: Set(defaults.stringArray(forKey: Keys.cleanAllIncluded) ?? []),
                cleanAllExcluded: Set(defaults.stringArray(forKey: Keys.cleanAllExcluded) ?? []),
                launchAtLogin: defaults.bool(forKey: Keys.launchAtLogin),
                rescanIntervalHours: defaults.object(forKey: Keys.rescanIntervalHours) as? Double
                    ?? SettingsModel.defaultRescanIntervalHours
            )
        }
    }

    /// nil = the default `<home>/Documents/Repositories` (ScanContext rule).
    var projectsRootPath: String? {
        get { model.projectsRootPath }
        set {
            model.projectsRootPath = newValue
            persist()
        }
    }

    /// What `ScanContext.init(projectsRoot:)` takes: nil keeps its default.
    var projectsRootURL: URL? {
        model.projectsRootPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    var launchAtLogin: Bool {
        get { model.launchAtLogin }
        set {
            model.launchAtLogin = newValue
            persist()
        }
    }

    var rescanIntervalHours: Double {
        get { model.rescanIntervalHours }
        set {
            model.setRescanIntervalHours(newValue)
            persist()
        }
    }

    var cleanAllIncludedIDs: Set<CategoryID> { model.cleanAllIncludedIDs }
    var cleanAllExcludedIDs: Set<CategoryID> { model.cleanAllExcludedIDs }

    func membership(of id: CategoryID) -> SettingsModel.CleanAllMembership {
        model.membership(of: id)
    }

    func setMembership(_ membership: SettingsModel.CleanAllMembership, for id: CategoryID) {
        model.setMembership(membership, for: id)
        persist()
    }

    /// Whole-model write on every mutation: five primitives, no fancy
    /// persistence. Sorted arrays keep the defaults plist diffable.
    private func persist() {
        guard let defaults else { return }
        if let path = model.projectsRootPath {
            defaults.set(path, forKey: Keys.projectsRootPath)
        } else {
            defaults.removeObject(forKey: Keys.projectsRootPath)
        }
        defaults.set(model.cleanAllIncluded.sorted(), forKey: Keys.cleanAllIncluded)
        defaults.set(model.cleanAllExcluded.sorted(), forKey: Keys.cleanAllExcluded)
        defaults.set(model.launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(model.rescanIntervalHours, forKey: Keys.rescanIntervalHours)
    }
}
