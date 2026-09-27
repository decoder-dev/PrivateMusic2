import Foundation

/// Short overlapping fade between consecutive progressive tracks.
///
/// Mirrors LMG-VK's two-player crossfade without bringing a second decode
/// graph onto HLS, EQ taps, Low Power Mode, or serious thermal state.
enum PlaybackTransitionPolicy {
    static let fadeDuration: TimeInterval = 0.55
    static let prepareLeadIn: TimeInterval = 1.25
    static func normalizedDuration(_ value: Double) -> Double {
        value.isFinite ? min(10, max(0.5, value)) : fadeDuration
    }

    static func shouldPrepareIncoming(
        remaining: TimeInterval,
        duration: TimeInterval,
        hasNextTrack: Bool,
        isRepeatOne: Bool,
        isAlreadyTransitioning: Bool,
        fadeSeconds: TimeInterval = fadeDuration
    ) -> Bool {
        guard hasNextTrack,
              !isRepeatOne,
              !isAlreadyTransitioning,
              duration > normalizedDuration(fadeSeconds) * 3,
              remaining.isFinite,
              remaining > 0 else {
            return false
        }
        return remaining <= max(prepareLeadIn, normalizedDuration(fadeSeconds) + 0.7)
    }

    static func shouldStartFade(
        remaining: TimeInterval,
        incomingIsReady: Bool,
        isAlreadyFading: Bool,
        fadeSeconds: TimeInterval = fadeDuration
    ) -> Bool {
        guard incomingIsReady, !isAlreadyFading else { return false }
        return remaining.isFinite && remaining > 0 && remaining <= normalizedDuration(fadeSeconds)
    }

    static func allowsCrossfade(
        userEnabled: Bool,
        currentURL: URL?,
        nextURL: URL?,
        requiresAudioTap: Bool,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        guard PlaybackResourcePolicy.allowOverlappingPlayback(
            userEnabled: userEnabled,
            requiresAudioTap: requiresAudioTap,
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        ) else {
            return false
        }
        if let currentURL, StreamQualityPolicy.isHLSStream(currentURL) {
            return false
        }
        if let nextURL, StreamQualityPolicy.isHLSStream(nextURL) {
            return false
        }
        return true
    }
}
