import Foundation

enum SpatialAudioDSP {
    static let defaultIntensity = 0.35
    /// High-pass the side channel so sub-bass stays mono. Keep this low so
    /// spatial width does not thin out the body of the mix («pipe» sound).
    static let sideHighPassFrequency: Double = 90

    static func process(
        left: Float,
        right: Float,
        intensity: Double,
        processedSide: Float? = nil
    ) -> (left: Float, right: Float) {
        var outLeft: Float = 0
        var outRight: Float = 0
        let side = processedSide ?? 0
        pm_spatial_widen(
            left,
            right,
            Float(intensity),
            side,
            processedSide != nil,
            &outLeft,
            &outRight
        )
        return (outLeft, outRight)
    }

    static func effectiveIntensity(
        userIntensity: Double,
        profile: PlaybackOutputToneProfile
    ) -> Double {
        min(max(userIntensity, 0), 1) * profile.spatialIntensityScale
    }
}
