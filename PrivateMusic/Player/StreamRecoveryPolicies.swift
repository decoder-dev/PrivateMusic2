import AVFoundation
import MediaPlayer

/// Network condition the player's buffer/retry policy reacts to,
/// derived from `NetworkMonitor.state`/`transport` (see the read-only
/// `NetworkMonitor.condition` computed property). Kept as its own tiny
/// value type so the retry math below never has to import `Network`.
enum NetworkCondition: Equatable {
    /// Wifi/wired, or an unconstrained cellular-adjacent path — the
    /// numbers `StreamFailureRetryPolicy` already shipped with.
    case nominal
    /// Cellular transport, or a constrained/expensive path — the
    /// 4G→3G collapse this policy exists to survive.
    case degraded
    /// No usable path at all. Sizing stays at the nominal numbers:
    /// there is nothing to buffer into, and connectivity failures
    /// already keep retrying the same track without advancing.
    case offline
}

/// Same-track recovery before auto-skip on flaky networks / stale CDN URLs.
enum StreamFailureRetryPolicy {
    static let maximumSameTrackAttempts = 3
    static let maximumConnectivityAttempts = 8
    static let preferredForwardBufferDuration: TimeInterval = 30
    static let stallRecoveryThreshold: TimeInterval = 20
    static let baseRetryDelay: TimeInterval = 1.2

    static func retryDelay(
        forAttempt attempt: Int,
        condition: NetworkCondition = .nominal
    ) -> TimeInterval {
        let clamped = max(attempt, 1)
        let base = min(baseRetryDelay * Double(clamped), 6)
        return NetworkAdaptiveBufferPolicy.retryDelay(
            base: base,
            condition: condition
        )
    }

    static func isConnectivityFailure(_ error: Error?) -> Bool {
        if let apiError = error as? APIError {
            return apiError.isConnectivityFailure
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Connectivity retry budget for the given network condition. Wifi
    /// and offline keep `maximumConnectivityAttempts` unchanged; a
    /// degraded link only ever gets *more* room, never less.
    static func maximumConnectivityAttempts(
        for condition: NetworkCondition
    ) -> Int {
        NetworkAdaptiveBufferPolicy.maximumConnectivityAttempts(
            baseline: maximumConnectivityAttempts,
            condition: condition
        )
    }

    /// Keep the current track while retries remain. Connectivity failures
    /// get a larger budget — wider still on a degraded link — and never
    /// auto-advance the queue.
    static func shouldRetrySameTrack(
        attempts: Int,
        error: Error?,
        condition: NetworkCondition = .nominal
    ) -> Bool {
        if isConnectivityFailure(error) {
            return attempts <= maximumConnectivityAttempts(for: condition)
        }
        return attempts <= maximumSameTrackAttempts
    }

    static func shouldAdvance(
        attempts: Int,
        error: Error?,
        advanceOnPlaybackError: Bool
    ) -> Bool {
        guard advanceOnPlaybackError else { return false }
        if isConnectivityFailure(error) { return false }
        return attempts > maximumSameTrackAttempts
    }
}

/// Bounded retry for `AVAudioSession.setActive(true)` failures.
///
/// Right after a phone call ends or media services reset, the session can
/// still be busy tearing itself down: the very next `setActive(true)`
/// throws even though intent to play is real. That throw used to be
/// swallowed with `try?` and nothing else ever tried again, so playback
/// stayed silently dead until the user reopened the app. This policy caps
/// how many times activation is retried and how long each wait is, so a
/// transient failure heals itself without ever retrying forever.
enum SessionActivationRetryPolicy {
    static let maximumAttempts = 3
    static let baseRetryDelay: TimeInterval = 0.3
    static let maximumRetryDelay: TimeInterval = 2

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(attempt, 1)
        return min(baseRetryDelay * Double(clamped), maximumRetryDelay)
    }

    /// Whether another retry is worth scheduling after `attempt` failures.
    static func shouldRetry(attempt: Int) -> Bool {
        attempt < maximumAttempts
    }
}

/// Guards `recoverFromExtendedStall` against a recovery/refresh task whose
/// reference was never cleared — e.g. a task whose guard clause returned
/// early (generation/track mismatch) without reaching the code path that
/// nils the stored task out. Once a task has been blocking recovery for
/// longer than any legitimate same-track retry cycle could still be
/// running, treat it as orphaned so a fresh recovery attempt can proceed
/// instead of the stall guard wedging shut forever.
enum StallRecoveryGuardPolicy {
    static let orphanThreshold: TimeInterval = 20

    static func isOrphaned(blockedSince: Date?, now: Date) -> Bool {
        guard let blockedSince else { return false }
        return now.timeIntervalSince(blockedSince) >= orphanThreshold
    }
}

/// Makes the forward-buffer target, connectivity retry budget and retry
/// backoff functions of `NetworkCondition` instead of the fixed
/// `StreamFailureRetryPolicy` constants, so a mid-track 4G→3G collapse
/// requests a bigger buffer and backs off more gently instead of
/// draining a fixed 30s window and stalling.
///
/// `.nominal` reproduces `StreamFailureRetryPolicy`'s existing numbers
/// exactly, so every current pin on those numbers stays green. Degraded
/// conditions are additive only — never a smaller buffer, never fewer
/// retry attempts, never a shorter backoff than the wifi baseline.
enum NetworkAdaptiveBufferPolicy {
    /// Extra forward-buffer seconds requested once the link is
    /// cellular/constrained, on top of the wifi baseline. A bandwidth
    /// collapse mid-track drains whatever is already buffered before
    /// the retry loop even starts, so the margin has to outlast that
    /// drain, not just the next retry.
    static let degradedBufferBonus: TimeInterval = 15
    /// Extra connectivity retry attempts allowed once the link is
    /// degraded. Connectivity failures never auto-advance the queue
    /// regardless (`StreamFailureRetryPolicy.shouldAdvance`), so a
    /// larger budget only buys more time on the same track.
    static let degradedConnectivityAttemptBonus = 4
    /// Backoff grows more slowly on a degraded link — a brief bandwidth
    /// dip should not burn through the retry budget before the CDN
    /// recovers — but stays capped well short of an unbounded wait.
    static let degradedRetryDelayMultiplier: Double = 1.6
    static let degradedRetryDelayCap: TimeInterval = 12

    static func preferredForwardBuffer(
        for condition: NetworkCondition
    ) -> TimeInterval {
        switch condition {
        case .nominal, .offline:
            return StreamFailureRetryPolicy.preferredForwardBufferDuration
        case .degraded:
            return StreamFailureRetryPolicy.preferredForwardBufferDuration
                + degradedBufferBonus
        }
    }

    static func maximumConnectivityAttempts(
        baseline: Int,
        condition: NetworkCondition
    ) -> Int {
        switch condition {
        case .nominal, .offline:
            return baseline
        case .degraded:
            return baseline + degradedConnectivityAttemptBonus
        }
    }

    static func retryDelay(
        base: TimeInterval,
        condition: NetworkCondition
    ) -> TimeInterval {
        switch condition {
        case .nominal, .offline:
            return base
        case .degraded:
            return min(base * degradedRetryDelayMultiplier, degradedRetryDelayCap)
        }
    }
}

/// Owns recovery work when reachability changes. In-flight refreshes are
/// suspended offline without spending the outer same-track budget; the first
/// usable path then gets a short jittered restart instead of inheriting a stale
/// multi-second backoff.
enum StreamRecoveryNetworkTransitionPolicy {
    enum Action: Equatable {
        case none
        case suspend
        case recover
    }

    static func action(
        from previous: NetworkCondition,
        to current: NetworkCondition
    ) -> Action {
        guard previous != current else { return .none }
        if current == .offline { return .suspend }
        if previous == .offline { return .recover }
        return .none
    }
}

/// Adds jitter to playback recovery without changing the established baseline
/// delays exposed by `StreamFailureRetryPolicy`. A network-return attempt uses
/// a separate sub-second window so reconnecting devices neither stampede the
/// API simultaneously nor wait for the backoff that belonged to the old path.
enum StreamRecoveryDelayPolicy {
    enum Trigger: Equatable {
        case failure
        case networkReturn
    }

    static let jitterFraction = 0.15
    static let networkReturnMinimumDelay: TimeInterval = 0.1
    static let networkReturnMaximumDelay: TimeInterval = 0.5

    static func delay(
        for trigger: Trigger,
        attempt: Int,
        condition: NetworkCondition,
        jitterUnit: Double
    ) -> TimeInterval {
        let unit = min(max(jitterUnit, 0), 1)
        switch trigger {
        case .networkReturn:
            return networkReturnMinimumDelay
                + (networkReturnMaximumDelay - networkReturnMinimumDelay) * unit
        case .failure:
            let base = StreamFailureRetryPolicy.retryDelay(
                forAttempt: attempt,
                condition: condition
            )
            let multiplier = (1 - jitterFraction)
                + (2 * jitterFraction * unit)
            let cap = condition == .degraded
                ? NetworkAdaptiveBufferPolicy.degradedRetryDelayCap
                : 6
            return min(max(base * multiplier, 0.2), cap)
        }
    }

    static func delay(
        for trigger: Trigger,
        attempt: Int,
        condition: NetworkCondition
    ) -> TimeInterval {
        delay(
            for: trigger,
            attempt: attempt,
            condition: condition,
            jitterUnit: Double.random(in: 0...1)
        )
    }
}

/// Play/lock-screen/headphones resume must never call `play()` on a
/// `.failed` or missing `AVPlayerItem`. After same-track retries run out
/// the item stays failed and KVO is deduped, so tapping play used to be a
/// silent no-op.
enum PlaybackResumePolicy {
    enum Action: Equatable {
        case refreshStream
        case reload
        case playExisting
    }

    static func action(
        requiresStreamRefresh: Bool,
        hasPlayableStream: Bool,
        canRefreshStream: Bool,
        hasCurrentItem: Bool,
        itemFailed: Bool,
        loadedTrackMatchesCurrent: Bool
    ) -> Action {
        if itemFailed && canRefreshStream {
            return .refreshStream
        }
        if requiresStreamRefresh && !hasPlayableStream {
            return .refreshStream
        }
        if !hasCurrentItem || itemFailed || !loadedTrackMatchesCurrent {
            return .reload
        }
        return .playExisting
    }
}

/// Missing or still-masked VK URLs are not connectivity timeouts. Treating
/// them as `timedOut` burned the 8–12 attempt budget and left the track
/// hanging on “loading…”. One getById refresh, then skip or surface
/// “no stream”.
enum StreamURLLoadPolicy {
    static let missingStreamError = APIError.invalidResponse

    static func isMaskedVKStream(_ url: URL) -> Bool {
        url.absoluteString.contains("audio_api_unavailable")
    }

    static func isPlayableRemoteURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !isMaskedVKStream(url)
    }

    static func shouldRetryMissingStream(attempts: Int) -> Bool {
        attempts <= 1
    }

    static func shouldAdvanceAfterMissingStream(
        attempts: Int,
        advanceOnPlaybackError: Bool
    ) -> Bool {
        guard advanceOnPlaybackError else { return false }
        return attempts > 1
    }

    /// Restored snapshots often still have a concrete https URL. Play that
    /// immediately and let failure recovery refresh if it is stale. Only
    /// block on getById when there is nothing playable.
    static func shouldBlockRestoreOnRefresh(
        isRestored: Bool,
        hasOfflineURL: Bool,
        streamURL: URL?
    ) -> Bool {
        guard isRestored, !hasOfflineURL else { return false }
        return !isPlayableRemoteURL(streamURL)
    }
}

/// VK binds a stream URL to the session that minted it, so rotating the
/// token kills every URL already sitting in the queue — not eventually, at
/// once. The player used to find that out one track at a time: play, 404,
/// re-resolve, play. A queue of 186 tracks means 186 failures and 186
/// extra round trips, and on a constrained cellular link the listener
/// hears every one of them as a stall between tracks.
///
/// Nothing about such a URL looks wrong, so it cannot be spotted by
/// inspecting it — the only thing that marks it is which session it came
/// from.
enum StreamCredentialPolicy {
    static func shouldRefreshBeforePlay(
        isStale: Bool,
        hasOfflineURL: Bool,
        hasRemoteURL: Bool,
        canRefresh: Bool
    ) -> Bool {
        // A downloaded file has no credentials to go stale, and refusing
        // to play it because the token moved would break offline playback
        // exactly when the network is worst.
        guard isStale, !hasOfflineURL, hasRemoteURL, canRefresh else {
            return false
        }
        return true
    }
}

/// A refresh whose index no longer matches (shuffle / play-next) used to
/// return without nilling `streamRefreshTask`, so every later play, restore
/// and network-return no-op'd on `guard streamRefreshTask == nil`.
enum StreamRefreshApplyPolicy {
    static func shouldApply(
        requestedTrackID: String,
        currentTrackID: String?
    ) -> Bool {
        currentTrackID == requestedTrackID
    }

    static func shouldClearSlot(
        taskGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        taskGeneration == currentGeneration
    }
}

/// Stall recovery while `.offline` spends the same-track budget and parks a
/// failure-backoff timer in the recovery slot, so the offline→online kick
/// sees a busy slot and refuses the short network-return window.
enum StallRecoveryEligibilityPolicy {
    static func shouldRecover(
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        condition: NetworkCondition
    ) -> Bool {
        playbackIntended && hasCurrentTrack && condition != .offline
    }
}

/// Network-return kick is independent of an in-flight failure backoff: that
/// timer belongs to the dead path and must be replaced, not waited out.
enum NetworkReturnKickPolicy {
    static func shouldKick(
        condition: NetworkCondition,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isAudioInterrupted: Bool,
        isPlaying: Bool,
        isBuffering: Bool
    ) -> Bool {
        condition != .offline
            && playbackIntended
            && hasCurrentTrack
            && !isAudioInterrupted
            && (!isPlaying || isBuffering)
    }

    static func shouldCancelFailureBackoff(
        from previous: NetworkCondition,
        to current: NetworkCondition
    ) -> Bool {
        StreamRecoveryNetworkTransitionPolicy.action(
            from: previous,
            to: current
        ) == .recover
    }
}
