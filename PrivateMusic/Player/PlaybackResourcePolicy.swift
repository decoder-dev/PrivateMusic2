import Foundation

/// Power- and thermal-aware playback decisions so HQ progressive streams and
/// realtime DSP stay off the hot path when the device is already constrained.
enum PlaybackResourcePolicy {
    /// Rewrite VK HLS to progressive MP3 only when the device can afford the
    /// extra decode/buffer work. MP3 is still lighter than HPS segment churn
    /// for AVPlayer, but skipping the rewrite on low power keeps the ladder
    /// and avoids a second URL attempt on weak networks.
    ///
    /// `requiresAudioProcessing` is the second reason to rewrite, and it is
    /// not about quality at all: `MTAudioProcessingTap` cannot attach to an
    /// HLS playlist, so a listener who turned the data saver on lost the
    /// equalizer, loudness normalization, dynamic range compression and
    /// spatial audio with it — silently, while every one of those toggles
    /// still read as on. Processing the user explicitly asked for outranks
    /// the ladder; the peak-bitrate cap still applies either way.
    static func allowProgressiveStreamUpgrade(
        preferHighQuality: Bool,
        requiresAudioProcessing: Bool = false,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard preferHighQuality || requiresAudioProcessing else {
            return false
        }
        guard !lowPowerMode else { return false }
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

    /// Overlapping two AVPlayers for a short crossfade. Skip when the
    /// device is already decoding under constraint or running a tap.
    static func allowOverlappingPlayback(
        userEnabled: Bool,
        requiresAudioTap: Bool,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard userEnabled, !requiresAudioTap, !lowPowerMode else {
            return false
        }
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
