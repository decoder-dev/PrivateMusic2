import Foundation

/// MPNowPlayingInfoCenter extrapolates elapsed time from rate until the next update.
enum NowPlayingTimelinePolicy {
    static func duration(actual: TimeInterval?, fallback: TimeInterval) -> TimeInterval? {
        if let actual, actual.isFinite, actual > 0 { return actual }
        return fallback.isFinite && fallback > 0 ? fallback : nil
    }

    static func elapsed(_ value: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let finite = value.isFinite ? max(0, value) : 0
        guard let duration, duration.isFinite, duration > 0 else { return finite }
        return min(finite, duration)
    }

    static func rate(intendsPlayback: Bool, isAdvancing: Bool, playerRate: Float) -> Float {
        guard intendsPlayback, isAdvancing, playerRate.isFinite, playerRate > 0 else { return 0 }
        return playerRate
    }
}
