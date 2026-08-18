import CoreGraphics
import Foundation

/// Pure progress math for the compact mini player scrubber.
enum MiniPlayerProgressPolicy {
    /// Returns a unit progress clamped to `0...1`. Unknown or non-positive
    /// durations always yield `0`; negative elapsed time does not go below `0`.
    static func progress(
        elapsedTime: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsedTime / duration, 0), 1)
    }

    /// Maps a tap/drag X in a track of `width` to a seek time.
    static func seekTime(
        x: CGFloat,
        width: CGFloat,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard width > 0, duration.isFinite, duration > 0 else { return nil }
        let fraction = min(max(Double(x / width), 0), 1)
        return fraction * duration
    }
}
