import Foundation
import IOKit.ps

/// Power/thermal gate for SCHEDULED rescans only (user-initiated refreshes
/// always run). Gated when any of:
/// - Low Power Mode is on
/// - thermal state is `.serious` or worse
/// - running on battery at or below 20%
///
/// Machines without an internal battery (desktops) report no battery
/// snapshot and default to allowed.
enum ScanGate {
    static let minimumBatteryPercent = 20

    static var isGated: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled { return true }
        if processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return true
        }
        if let battery = batterySnapshot(),
            battery.onBattery, battery.percent <= minimumBatteryPercent
        {
            return true
        }
        return false
    }

    /// First internal battery from IOPSCopyPowerSourcesInfo, or nil when
    /// there is none (desktop) or the query fails — both default-allowed.
    private static func batterySnapshot() -> (onBattery: Bool, percent: Int)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let max = description[kIOPSMaxCapacityKey] as? Int,
                max > 0
            else { continue }
            let onBattery =
                description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (onBattery: onBattery, percent: current * 100 / max)
        }
        return nil
    }
}
