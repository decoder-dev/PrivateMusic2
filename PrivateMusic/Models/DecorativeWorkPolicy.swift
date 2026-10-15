import Foundation

/// Optional visual work must yield to playback when the device is constrained.
enum DecorativeWorkPolicy {
    static func allowsSpeculativeWork(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        guard !lowPowerMode else { return false }
        switch thermalState {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }

    static var allowsSpeculativeWork: Bool {
        allowsSpeculativeWork(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                              thermalState: ProcessInfo.processInfo.thermalState)
    }
}
