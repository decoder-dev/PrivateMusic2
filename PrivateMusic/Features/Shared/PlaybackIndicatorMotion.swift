import Foundation

enum PlaybackIndicatorMotion {
    static let staticHeights: [Double] = [0.46, 0.88, 0.66, 0.38]

    static func heightFraction(bar: Int, elapsed: TimeInterval, animated: Bool) -> Double {
        guard staticHeights.indices.contains(bar) else { return 0.46 }
        guard animated, elapsed.isFinite else { return staticHeights[bar] }
        let phase = elapsed.truncatingRemainder(dividingBy: 3.2) / 3.2 * 2 * .pi
        return 0.26 + 0.74 * (sin(phase + Double(bar) * 1.35) + 1) / 2
    }
}
