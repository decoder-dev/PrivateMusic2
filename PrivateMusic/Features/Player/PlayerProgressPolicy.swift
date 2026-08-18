import Foundation

/// Pure progress math for the full-screen player scrubber.
enum PlayerProgressPolicy {
    static let timeLabelFontSize: CGFloat = 11
    static let timeRowHeight: CGFloat = 16
    static let sliderTrackHeight: CGFloat = 20
    static let thumbDiameter: CGFloat = 12

    static func displayedElapsed(
        scrubPosition: TimeInterval?,
        elapsedTime: TimeInterval
    ) -> TimeInterval {
        scrubPosition ?? elapsedTime
    }

    static func remainingTime(
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        max(duration - elapsed, 0)
    }

    static func sliderRange(duration: TimeInterval) -> ClosedRange<TimeInterval> {
        0 ... max(duration, 1)
    }
}
