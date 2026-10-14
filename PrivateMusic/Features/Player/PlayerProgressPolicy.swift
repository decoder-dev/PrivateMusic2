import Foundation

/// Pure progress math for the full-screen player scrubber.
enum PlayerProgressPolicy {
    static let timeLabelFontSize: CGFloat = 11
    static let timeRowHeight: CGFloat = 16
    static let sliderTrackHeight: CGFloat = 20
    /// What the finger can grab: the slider is drawn 20pt tall but its
    /// touch area is the full 44pt, centred on the same line.
    static let sliderTouchHeight: CGFloat = 44
    static let thumbDiameter: CGFloat = 12

    static func shouldAnimateStep(from previous: TimeInterval, to next: TimeInterval, reduceMotion: Bool) -> Bool {
        !reduceMotion && previous.isFinite && next.isFinite && next > previous && next - previous <= 1
    }

    static func displayedElapsed(
        scrubPosition: TimeInterval?,
        elapsedTime: TimeInterval
    ) -> TimeInterval {
        let value = scrubPosition ?? elapsedTime
        return value.isFinite ? max(0, value) : 0
    }

    static func remainingTime(
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(duration - (elapsed.isFinite ? max(0, elapsed) : 0), 0)
    }

    static func sliderRange(duration: TimeInterval) -> ClosedRange<TimeInterval> {
        0 ... (duration.isFinite ? max(duration, 1) : 1)
    }
}
