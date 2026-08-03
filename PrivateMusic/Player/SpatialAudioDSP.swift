import Foundation

enum SpatialAudioDSP {
    static let defaultIntensity = 0.35
    /// Softer than a raw 1.35 widen — aggressive side gain is what makes
    /// cars and speakers sound hollow once they mono-sum the image.
    private static let maximumSideGain: Float = 1.22
    /// High-pass the side channel so bass stays mono (centered in mid).
    static let sideHighPassFrequency: Double = 180

    static func process(
        left: Float,
        right: Float,
        intensity: Double,
        processedSide: Float? = nil
    ) -> (left: Float, right: Float) {
        let amount = Float(min(max(intensity, 0), 1))
        guard amount > 0 else { return (left, right) }

        let mid = (left + right) * 0.5
        let side = processedSide ?? (left - right) * 0.5
        let sideGain = 1 + (maximumSideGain - 1) * amount
        // Fixed headroom keeps every frame in range without the harmonic
        // distortion and pumping of a sample-by-sample limiter.
        let headroom = 1 / sideGain
        return (
            (mid + side * sideGain) * headroom,
            (mid - side * sideGain) * headroom
        )
    }

    static func effectiveIntensity(
        userIntensity: Double,
        profile: PlaybackOutputToneProfile
    ) -> Double {
        min(max(userIntensity, 0), 1) * profile.spatialIntensityScale
    }
}
