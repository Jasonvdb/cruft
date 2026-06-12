import Foundation
import ServiceManagement

/// Thin `SMAppService.mainApp` wrapper. The Settings toggle drives
/// `setEnabled` and then re-reads `isEnabled`/`status` — registration can
/// be refused or parked on user approval (System Settings → Login Items),
/// so the read-back, never the click, is the displayed truth.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
