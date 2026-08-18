import Foundation

/// Power- and thermal-aware playback decisions so HQ progressive streams and
/// realtime DSP stay off the hot path when the device is already constrained.
enum PlaybackResourcePolicy {
    /// Rewrite VK HLS to progressive MP3 only when the device can afford the
    /// extra decode/buffer work. MP3 is still lighter than HPS segment churn
    /// for AVPlayer, but skipping the rewrite on low power keeps the ladder
    /// and avoids a second URL attempt on weak networks.
    static func allowProgressiveStreamUpgrade(
        preferHighQuality: Bool,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard preferHighQuality, !lowPowerMode else { return false }
        return !thermalState.shouldThrottlePlaybackProcessing
    }

    /// `MTAudioProcessingTap` runs per audio buffer on the realtime thread —
    /// the main CPU cost after switching off HLS. Skip it under constraint
    /// even when the user preset is still enabled; settings stay, processing
    /// resumes automatically when headroom returns.
    static func allowRealtimeAudioProcessing(
        requiresAudioTap: Bool,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard requiresAudioTap, !lowPowerMode else { return false }
        return !thermalState.shouldThrottlePlaybackProcessing
    }
}

private extension ProcessInfo.ThermalState {
    var shouldThrottlePlaybackProcessing: Bool {
        switch self {
        case .nominal, .fair:
            return false
        case .serious, .critical:
            return true
        @unknown default:
            return false
        }
    }
}
