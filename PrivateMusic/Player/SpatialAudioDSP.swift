import Foundation

enum SpatialAudioDSP {
    static let defaultIntensity = 0.35
    private static let maximumSideGain: Float = 1.35

    static func process(
        left: Float,
        right: Float,
        intensity: Double
    ) -> (left: Float, right: Float) {
        let amount = Float(min(max(intensity, 0), 1))
        guard amount > 0 else { return (left, right) }

        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let sideGain = 1 + (maximumSideGain - 1) * amount
        // Fixed headroom keeps every frame in range without the harmonic
        // distortion and pumping of a sample-by-sample limiter.
        let headroom = 1 / sideGain
        return (
            (mid + side * sideGain) * headroom,
            (mid - side * sideGain) * headroom
        )
    }
}
