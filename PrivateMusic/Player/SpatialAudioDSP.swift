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
        var widenedLeft = mid + side * sideGain
        var widenedRight = mid - side * sideGain

        // Keep the stereo balance while preventing widening from clipping.
        let peak = max(abs(widenedLeft), abs(widenedRight))
        if peak > 1 {
            widenedLeft /= peak
            widenedRight /= peak
        }
        return (widenedLeft, widenedRight)
    }
}
