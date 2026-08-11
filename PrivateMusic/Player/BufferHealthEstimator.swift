import Foundation

/// Swift-friendly wrapper around the fixed-memory `pm_buffer_health_*` ring
/// buffer estimator in `PrivateMusicCore.c`.
///
/// A class, not a struct: the C struct holds a few hundred bytes of POD
/// state that is updated on every periodic-time-observer tick (~2 Hz, more
/// under stall polling), and reference semantics let one long-lived instance
/// per item be updated in place without copying that state on every read.
///
/// This type only estimates; it does not sample `AVPlayerItem` itself and it
/// does not decide a forward-buffer target. The call site that feeds samples
/// in (from `loadedTimeRanges`) and reads a `Hint` back out to size the
/// buffer belongs to the network-aware buffer policy.
final class BufferHealthEstimator {
    /// One read of both estimator outputs, captured as a value so a caller
    /// can compare or log a policy decision without re-reading the C state.
    struct Hint: Equatable {
        /// Smoothed loaded-seconds-per-wall-second, as a multiple of normal
        /// playback speed. `1.0` is steady state (download matches
        /// playback); below `1.0` the buffer is draining.
        let throughput: Double

        /// Predicted seconds until the buffer runs dry, or
        /// `BufferHealthEstimator.noUnderrun` when the estimator does not
        /// see the buffer draining.
        let predictedUnderrunSeconds: TimeInterval

        /// Whether this read predicts an underrun within `horizon`
        /// wall-seconds — the question a buffer policy actually wants to
        /// branch on, rather than comparing against the raw sentinel.
        func isUnderrunImminent(within horizon: TimeInterval) -> Bool {
            predictedUnderrunSeconds < horizon
        }
    }

    /// Mirrors `PM_BUFFER_HEALTH_UNDERRUN_NONE`: the value
    /// `predictedUnderrun` reports when the buffer is not draining.
    static let noUnderrun: TimeInterval = PM_BUFFER_HEALTH_UNDERRUN_NONE

    private var state = pm_buffer_health()

    init() {
        pm_buffer_health_reset(&state)
    }

    /// Forget every sample, as if newly constructed. Call this when a new
    /// item loads so a track switch does not blend its history with the
    /// last track's throughput.
    func reset() {
        pm_buffer_health_reset(&state)
    }

    /// Record one `loadedTimeRanges` sample. `now` should be a monotonic
    /// clock (e.g. `CACurrentMediaTime()`, not `Date()`); `loadedAheadSeconds`
    /// is how far the loaded range extends past the current playback
    /// position.
    func observe(now: TimeInterval, loadedAheadSeconds: TimeInterval) {
        pm_buffer_health_observe(&state, now, loadedAheadSeconds)
    }

    /// Smoothed loaded-seconds-per-wall-second over the current window.
    var throughput: Double {
        pm_buffer_health_throughput(&state)
    }

    /// Predicted seconds until the buffer runs dry at `playRate` (`1.0` for
    /// normal speed).
    func predictedUnderrun(playRate: Double = 1.0) -> TimeInterval {
        pm_buffer_health_predicted_underrun(&state, playRate)
    }

    /// Both current outputs, read together.
    func hint(playRate: Double = 1.0) -> Hint {
        Hint(
            throughput: throughput,
            predictedUnderrunSeconds: predictedUnderrun(playRate: playRate)
        )
    }
}
