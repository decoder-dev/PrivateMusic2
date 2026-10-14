import AVFoundation
import MediaPlayer

/// Exact seeks force AVFoundation to decode to a precise frame — expensive on
/// remote / HLS streams and a common source of scrub stalls. Local files can
/// stay frame-accurate cheaply.
enum PlaybackSeekTolerancePolicy {
    static let remoteToleranceSeconds: TimeInterval = 0.35

    static func tolerance(isOffline: Bool) -> CMTime {
        if isOffline { return .zero }
        return CMTime(
            seconds: remoteToleranceSeconds,
            preferredTimescale: 600
        )
    }
}

/// Now Playing Center interpolates elapsed time from rate; writing the info
/// dictionary every second is pure XPC churn. Correct drift occasionally.
enum NowPlayingDriftPolicy {
    static let correctionIntervalSeconds = 30

    static func shouldPublish(
        elapsedSeconds: Int,
        lastPublishedSecond: Int,
        force: Bool
    ) -> Bool {
        if force { return true }
        if lastPublishedSecond < 0 { return true }
        return abs(elapsedSeconds - lastPublishedSecond) >= correctionIntervalSeconds
    }
}

enum PlaybackPreloadPolicy {
    static let maximumAge: TimeInterval = 5 * 60
    /// Forward buffer while a track just sits in the preload slot — warms
    /// roughly the first 10s of the upcoming track (streaming-service
    /// style "warm start") without downloading, or holding in memory,
    /// the whole file the way a full prefetch would.
    static let preferredForwardBufferDuration: TimeInterval = 10

    /// Buffer duration to apply to a track's `AVPlayerItem`, depending on
    /// whether it is merely warming up in the preload slot or has been
    /// promoted to the actively playing item. Promoted items switch to
    /// `NetworkAdaptiveBufferPolicy`'s buffer for stall resilience,
    /// which widens further on a degraded/cellular link.
    static func forwardBufferDuration(
        isActivePlayback: Bool,
        condition: NetworkCondition = .nominal
    ) -> TimeInterval {
        isActivePlayback
            ? NetworkAdaptiveBufferPolicy.preferredForwardBuffer(
                for: condition
              )
            : preferredForwardBufferDuration
    }

    static func nextIndex(
        queueCount: Int,
        currentIndex: Int?,
        repeatMode: RepeatMode
    ) -> Int? {
        guard queueCount > 1,
              let currentIndex,
              (0..<queueCount).contains(currentIndex) else {
            return nil
        }
        if currentIndex + 1 < queueCount {
            return currentIndex + 1
        }
        return repeatMode == .all ? 0 : nil
    }

    static func isValid(
        trackID: String,
        url: URL,
        preparedTrackID: String,
        preparedURL: URL,
        preparedAt: Date,
        now: Date = Date()
    ) -> Bool {
        trackID == preparedTrackID
            && url == preparedURL
            && now.timeIntervalSince(preparedAt) < maximumAge
    }

    static func hasQueueChanged(_ lhs: [Track], _ rhs: [Track]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        return zip(lhs, rhs).contains { left, right in
            left.id != right.id || left.streamURL != right.streamURL
        }
    }
}

enum ContinuationAdvancePolicy {
    static func shouldAdvance(
        requested: Bool,
        playbackIntended: Bool
    ) -> Bool {
        requested && playbackIntended
    }
}


/// How often the playback clock is sampled. On screen the progress UI wants
/// two ticks a second; with the screen off or another app in front nothing
/// draws it, and every tick is a CPU wake-up that keeps the device out of
/// idle for the length of the listening session.
enum PlaybackClockPolicy {
    static let activeInterval: TimeInterval = 0.5
    static let backgroundInterval: TimeInterval = 2

    /// Only a feasible, approaching crossfade needs the fast background clock.
    /// One coarse tick of headroom prevents stepping over its preparation window.
    static func needsFastCrossfadeClock(
        eligible: Bool,
        remaining: TimeInterval,
        fadeSeconds: TimeInterval
    ) -> Bool {
        guard eligible, remaining.isFinite, remaining > 0 else { return false }
        let preparation = max(
            PlaybackTransitionPolicy.prepareLeadIn,
            PlaybackTransitionPolicy.normalizedDuration(fadeSeconds) + 0.7
        )
        return remaining <= preparation + backgroundInterval
    }

    /// The caller passes actual crossfade eligibility, not the saved preference.
    static func interval(
        interfaceActive: Bool,
        crossfadeEnabled: Bool
    ) -> TimeInterval {
        interfaceActive || crossfadeEnabled
            ? activeInterval
            : backgroundInterval
    }

    /// Largest gap between two ticks that still counts as continuous
    /// listening. Tied to the tick so the slow clock does not stop crediting
    /// listened time (history, "listened" marks).
    static func maximumListenDelta(forInterval interval: TimeInterval) -> TimeInterval {
        max(1.5, interval * 3)
    }

    /// True once at least `period` whole seconds have passed since the last
    /// persisted second — robust to ticks that never land on an exact multiple.
    static func shouldPersist(
        wholeSecond: Int,
        lastPersistedSecond: Int,
        period: Int = 15
    ) -> Bool {
        // abs(): after a seek backwards the playhead is *behind* the last
        // persisted second and must still persist once `period` has passed.
        wholeSecond > 0
            && abs(wholeSecond - max(lastPersistedSecond, 0)) >= period
    }
}
