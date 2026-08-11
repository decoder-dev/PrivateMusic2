import AVFoundation
import Combine
import MediaPlayer

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

enum SleepTimerMode: Equatable, Sendable {
    case afterMinutes(Int)
    case endOfTrack
    case endOfQueue

    var statusLabel: String {
        switch self {
        case let .afterMinutes(minutes):
            return L10n.minutes(minutes)
        case .endOfTrack:
            return L10n.text("До конца трека")
        case .endOfQueue:
            return L10n.text("До конца очереди")
        }
    }
}

/// What started the current queue, for display in the full-screen player.
/// Callers that start playback from a named collection or from Медиатека
/// pass the matching case; anything else (search results, recommendations,
/// artist tracks, offline files, an "open player" context-menu action, …)
/// is left `nil` and treated as an implicit automix seeded by the tapped
/// track — see `AudioPlayer.queueContextTitle`.
enum QueueSource: Equatable {
    case mix(title: String)
    case playlist(title: String)
    case album(title: String)
    case history
    /// The Медиатека track list. It has no title of its own, and without a
    /// case for it the player captioned a library queue as a mix seeded by
    /// the tapped track — which is not what is playing.
    case library
}

enum PendingPlayerSheet: Equatable, Sendable {
    case queue
}

enum QueueSourceTitle {
    static func isUsable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Playback route policy for wired / wireless headphone disconnects.
///
/// Apple documents that media apps must pause when headphones are removed so
/// audio does not continue through the built-in speaker. See:
/// https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes
/// (`AVAudioSession.routeChangeNotification` +
/// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable`).
///
/// Single-AirPod Automatic Ear Detection is delivered as a remote pause /
/// interruption rather than a full route loss; `MPRemoteCommandCenter` and
/// `setPrefersInterruptionOnRouteDisconnect(true)` cover that path.
enum AudioRoutePolicy {
    static let minimumAudibleVolume: Float = 0.001

    static func shouldPause(
        volume: Float,
        enabled: Bool,
        isPlaying: Bool,
        outputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        enabled
            && isPlaying
            && volume <= minimumAudibleVolume
            && outputPortTypes.contains(where: supportsSystemVolumePause)
            && !outputPortTypes.contains(where: isExternalPlayback)
    }

    static func shouldResumeAfterMinimumVolumePause(
        volume: Float,
        enabled: Bool,
        pausedForMinimumVolume: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        outputPortTypes: [AVAudioSession.Port],
        isAudioInterrupted: Bool = false,
        allowsAutomaticResume: Bool = true
    ) -> Bool {
        guard pausedForMinimumVolume,
              playbackIntended,
              hasCurrentTrack,
              !isPlaying,
              !isAudioInterrupted,
              allowsAutomaticResume else {
            return false
        }
        let remainsMutedOnLocalOutput =
            enabled
            && volume <= minimumAudibleVolume
            && outputPortTypes.contains(where: supportsSystemVolumePause)
            && !outputPortTypes.contains(where: isExternalPlayback)
        return !remainsMutedOnLocalOutput
    }

    /// Returns true when an external listening route disappeared and playback
    /// must pause (wired headphones, AirPods / Bluetooth, AirPlay, car audio).
    static func shouldPauseAfterRouteLoss(
        wasPlaying: Bool,
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        wasPlaying
            && didLoseExternalRoute(
                previousOutputPortTypes: previousOutputPortTypes,
                currentOutputPortTypes: currentOutputPortTypes
            )
    }

    /// The route the app was listening on is gone and the session has
    /// fallen back to the device itself.
    ///
    /// This is `shouldPauseAfterRouteLoss` with the playback state left
    /// out, because the state is exactly what the disconnect race takes
    /// away: unplugging headphones raises an interruption *and* a route
    /// change, and when the interruption lands first it has already paused
    /// playback and cleared the flags that said we were playing. Reading
    /// the route alone is what recognises the disconnect either way.
    static func didLoseExternalRoute(
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        previousOutputPortTypes.contains(where: isExternalPlayback)
            && !currentOutputPortTypes.contains(where: isExternalPlayback)
    }

    static func shouldResumeAfterRouteTransfer(
        pendingResume: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        resumeBluetoothEnabled: Bool,
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard pendingResume,
              playbackIntended,
              hasCurrentTrack,
              !isPlaying,
              currentOutputPortTypes.contains(where: isExternalPlayback)
        else {
            return false
        }
        let usesBluetooth = currentOutputPortTypes.contains(where: isBluetooth)
        return !usesBluetooth || resumeBluetoothEnabled
    }

    private static func supportsSystemVolumePause(
        _ portType: AVAudioSession.Port
    ) -> Bool {
        portType == .builtInSpeaker || portType == .headphones
    }

    static func isBluetooth(_ portType: AVAudioSession.Port) -> Bool {
        [
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE
        ].contains(portType)
    }

    static func isExternalPlayback(_ portType: AVAudioSession.Port) -> Bool {
        isBluetooth(portType)
            || portType == .airPlay
            || portType == .headphones
            || portType == .lineOut
            || portType == .carAudio
            || portType == .HDMI
            || portType == .usbAudio
    }

    /// A route worn on the head: the only kind that can be taken off, and
    /// so the only kind whose interruption may be ear detection.
    static func isWearable(_ portType: AVAudioSession.Port) -> Bool {
        isBluetooth(portType) || portType == .headphones
    }

    /// Whether two route reads name the same worn device.
    ///
    /// Exact port identity is too strict: a pair of AirPods flickers
    /// between `.bluetoothA2DP` and `.bluetoothHFP` without ever leaving
    /// the ear, and an interruption that began on one and ended on the
    /// other is still the same buds.
    ///
    /// Wired and wireless are not interchangeable, though. Losing a cable
    /// to a pair of buds is a transfer, and transfers carry the playback
    /// over rather than stopping it.
    static func namesTheSameWornRoute(
        _ lhs: [AVAudioSession.Port],
        _ rhs: [AVAudioSession.Port]
    ) -> Bool {
        guard !lhs.isEmpty,
              !rhs.isEmpty,
              lhs.allSatisfy(isWearable),
              rhs.allSatisfy(isWearable) else {
            return false
        }
        if Set(lhs) == Set(rhs) { return true }
        return lhs.allSatisfy(isBluetooth) && rhs.allSatisfy(isBluetooth)
    }

    /// `.oldDeviceUnavailable` says the route we were listening on is gone,
    /// but `currentRoute` is read from a session that has not finished
    /// switching: it can still name the very device that just went away.
    ///
    /// Reading that stale route as "nothing was lost" is a speaker leak —
    /// a moment later the session lands on the built-in speaker with
    /// playback still running. The disconnect is therefore acted on
    /// whenever the route we were playing on is still in the answer, and
    /// re-checked once the route has settled.
    static func looksLikeStaleRouteLoss(
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard previousOutputPortTypes.contains(where: isExternalPlayback),
              currentOutputPortTypes.contains(where: isExternalPlayback) else {
            return false
        }
        return currentOutputPortTypes.contains {
            previousOutputPortTypes.contains($0)
        }
    }

    /// `.oldDeviceUnavailable` that arrives without a usable previous
    /// route.
    ///
    /// The payload is documented but not guaranteed: it goes missing when
    /// the notification is coalesced with a media-services restart, and a
    /// disconnect the app could not attribute used to fall straight
    /// through the pause branch. The reason itself already says a device
    /// went away, so landing on the phone's own output is the disconnect.
    static func isUnattributedRouteLoss(
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        previousOutputPortTypes.isEmpty
            && !currentOutputPortTypes.contains(where: isExternalPlayback)
    }

    /// Whether a route change carrying this reason may be read as playback
    /// losing the route it was running on.
    ///
    /// `.oldDeviceUnavailable` is the documented unplug and is handled on
    /// its own. These are the safety net for the disconnects that arrive
    /// without saying so — a wired unplug during sleep, a pair of buds the
    /// system drops without naming, a category the route cannot serve.
    ///
    /// `.override` and `.categoryChange` are deliberately left out: a user
    /// picking «iPhone» in the route picker is asking for the speaker, not
    /// losing a route, and pausing on them would fight the request.
    static func mayCarryAnUnannouncedDisconnect(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .unknown,
             .wakeFromSleep,
             .noSuitableRouteForCategory,
             .routeConfigurationChange:
            return true
        default:
            return false
        }
    }
}

/// Whether playback the *app* starts on its own — a stream retry, a stall
/// recovery, the next track, a session restart after media services died —
/// may begin right now.
///
/// None of those are the user asking to listen, so none of them may push
/// audio through the device speaker while the headphones that were playing
/// are gone. `routeDisconnectPending` is what says the disconnect has been
/// seen and no new route has taken over yet.
enum AudioAutoplayGatePolicy {
    static func allowsAutomaticPlayback(
        routeDisconnectPending: Bool,
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard routeDisconnectPending else { return true }
        return currentOutputPortTypes.contains(
            where: AudioRoutePolicy.isExternalPlayback
        )
    }

    /// Media services coming back does not put the headphones back on.
    ///
    /// The reset tears every flag down and rebuilds the session, and the
    /// route it rebuilds on is the phone itself. Dropping the pending
    /// disconnect there reopened the gate for the reload the reset
    /// schedules, which is the speaker leak on the CarKit path.
    static func retainsDisconnectPendingAfterReset(
        wasPending: Bool,
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        wasPending
            && !currentOutputPortTypes.contains(
                where: AudioRoutePolicy.isExternalPlayback
            )
    }
}

enum AppVolumePolicy {
    static func shouldPauseAtZero(
        volume: Float,
        isPlaying: Bool
    ) -> Bool {
        isPlaying && volume <= AudioRoutePolicy.minimumAudibleVolume
    }

    static func shouldResumeAfterZeroPause(
        volume: Float,
        pausedForAppVolumeZero: Bool,
        playbackIntended: Bool,
        hasCurrentTrack: Bool,
        isPlaying: Bool,
        isAudioInterrupted: Bool = false,
        allowsAutomaticResume: Bool = true
    ) -> Bool {
        volume > AudioRoutePolicy.minimumAudibleVolume
            && pausedForAppVolumeZero
            && playbackIntended
            && hasCurrentTrack
            && !isPlaying
            && !isAudioInterrupted
            && allowsAutomaticResume
    }
}

enum AudioProcessingRoutePolicy {
    /// Remote AVPlayer handoff bypasses `MTAudioProcessingTap`. While EQ or
    /// spatial processing is active, keep decoding on the phone so the tap
    /// runs for every local session route — built-in speaker, wired/wireless
    /// headphones, Bluetooth A2DP, and CarKit / `.carAudio`. AirPlay remains
    /// available as an output route and receives the already-processed signal.
    static func allowsExternalPlayback(requiresAudioTap: Bool) -> Bool {
        !requiresAudioTap
    }
}

/// Whether `MTAudioProcessingTap` can be attached for a given source URL.
///
/// Apple documents that `AVAudioMix` / audio taps work on file-based and
/// progressive remote assets once tracks are available. HLS (`m3u8`) does
/// not expose tap-ready tracks — attaching a mix there is a common cause of
/// `AVPlayerItem` failures on CarKit / Bluetooth reconnects. Streaming
/// services that keep EQ on car routes either decode locally (file / PCM)
/// or skip in-app DSP for HLS handoff.
enum AudioProcessingAttachPolicy {
    static func supportsAudioTap(url: URL, isOffline: Bool) -> Bool {
        if isOffline { return true }
        return url.pathExtension.caseInsensitiveCompare("m3u8") != .orderedSame
    }

    /// After media-services reset (typical on car attach), suppress auto-skip
    /// briefly so a transient item failure retries the same track instead of
    /// jumping through the queue with error toasts.
    static let postResetAdvanceSuppression: TimeInterval = 8
}

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
        guard elapsedSeconds != lastPublishedSecond else { return false }
        return elapsedSeconds % correctionIntervalSeconds == 0
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

enum AudioInterruptionPolicy {
    /// - Parameter beganAsRouteDisconnect: the system named the route
    ///   going away as the reason. Such an interruption still ends asking
    ///   for a resume, and obeying that is a speaker leak: the route it
    ///   named is gone, so only a route arriving may start playback again.
    static func shouldResume(
        wasPlayingBeforeInterruption: Bool,
        playbackIntended: Bool,
        routeDisconnectPending: Bool,
        beganAsRouteDisconnect: Bool,
        options: AVAudioSession.InterruptionOptions
    ) -> Bool {
        wasPlayingBeforeInterruption
            && playbackIntended
            && !routeDisconnectPending
            && !beganAsRouteDisconnect
            && options.contains(.shouldResume)
    }

    /// When interruption-on-route-disconnect ends before the route-change
    /// notification arrives, the current route may already be the built-in
    /// speaker while the previous route was headphones / BT / car.
    static func shouldTreatEndAsRouteDisconnect(
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        AudioRoutePolicy.shouldPauseAfterRouteLoss(
            wasPlaying: true,
            previousOutputPortTypes: previousOutputPortTypes,
            currentOutputPortTypes: currentOutputPortTypes
        )
    }

    /// Last-resort window for an interruption that nothing else explains.
    ///
    /// Only reached when another audio session was holding the output when
    /// the interruption began *and* the system refused to name a reason —
    /// the ambiguous corner where a very short foreign interruption is
    /// still likelier to be the buds than a call.
    static let deliberatePauseWindow: TimeInterval = 1.5

    /// Whether an interruption that began and ended on the same worn
    /// route is the user taking the headphones off rather than something
    /// borrowing the session for a moment.
    ///
    /// Automatic Ear Detection is the case this exists for. The AirPods
    /// stay connected, so nothing about the route changes, and the end
    /// arrives with `.shouldResume` — obeying it is what the reporter
    /// hears as «музыка не встаёт на паузу», with the buds in the case and
    /// the track playing on. Taking the headphones off is the user saying
    /// stop, exactly as if they had pressed pause on the buds themselves.
    ///
    /// Timing does not separate the two. The buds can sit out of an ear
    /// for a second or for an hour, and the interruption only ends when
    /// they go back in; a window narrow enough to exclude a call is far
    /// too narrow to cover that, and that gap is the defect. What does
    /// separate them is whether anything else was making sound.
    ///
    /// - Parameter beganAsRouteDisconnect: iOS 17 names the reason
    ///   (`.routeDisconnected`), which is the exact signal and needs no
    ///   inference at all — `setPrefersInterruptionOnRouteDisconnect(true)`
    ///   is what asks for it.
    /// - Parameter otherAudioWasPlaying: a call, Siri or another app owned
    ///   the output when the interruption began. Ear detection never looks
    ///   like that — the buds go quiet and nothing takes their place — so
    ///   these keep resuming the way they always did.
    static func shouldTreatEndAsDeliberatePause(
        beganAsRouteDisconnect: Bool,
        otherAudioWasPlaying: Bool,
        interruptionDuration: TimeInterval,
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard AudioRoutePolicy.namesTheSameWornRoute(
            previousOutputPortTypes,
            currentOutputPortTypes
        ) else {
            return false
        }
        if beganAsRouteDisconnect { return true }
        if !otherAudioWasPlaying { return true }
        return interruptionDuration <= deliberatePauseWindow
    }

    /// How long an interruption-end resume waits for the route to settle.
    ///
    /// The two notifications an unplug raises are not ordered: the
    /// interruption can end while `currentRoute` still names the
    /// headphones, and `.oldDeviceUnavailable` follows a moment later. The
    /// wait is what lets the route change arrive first and cancel the
    /// resume instead of the resume beating it into the speaker.
    static let routeSettleDelay: TimeInterval = 0.35

    /// Whether a resume scheduled at interruption end may still go ahead
    /// once the route has settled.
    ///
    /// Re-reading the route at that point is the second half of the fix:
    /// the route change can also arrive *after* the wait, and a resume that
    /// only checked the flags it captured when it was scheduled would have
    /// already pushed audio to the speaker by then.
    static func allowsDelayedResume(
        isAudioInterrupted: Bool,
        playbackIntended: Bool,
        routeDisconnectPending: Bool,
        previousOutputPortTypes: [AVAudioSession.Port],
        currentOutputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard !isAudioInterrupted,
              playbackIntended,
              !routeDisconnectPending else {
            return false
        }
        return !AudioRoutePolicy.didLoseExternalRoute(
            previousOutputPortTypes: previousOutputPortTypes,
            currentOutputPortTypes: currentOutputPortTypes
        )
    }
}

/// Whether to restart playback after AVAudioSession media services die
/// (common when attaching CarKit / Bluetooth head units).
enum MediaServicesResetPolicy {
    static func shouldAutoplayAfterReset(
        playbackIntended: Bool,
        wasActivelyPlaying: Bool
    ) -> Bool {
        playbackIntended && wasActivelyPlaying
    }

    static func shouldSuppressAdvance(
        now: Date,
        suppressUntil: Date?
    ) -> Bool {
        guard let suppressUntil else { return false }
        return now < suppressUntil
    }
}

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

@MainActor
final class AudioPlayer: ObservableObject {
    private final class PreloadedPlayback {
        let trackID: String
        let url: URL
        let asset: AVURLAsset
        /// Created eagerly — not lazily inside `takePreloadedPlayback` —
        /// so AVFoundation starts fetching data for the upcoming track
        /// while it still just sits in the preload slot. Its
        /// `preferredForwardBufferDuration` is capped to
        /// `PlaybackPreloadPolicy.preferredForwardBufferDuration`
        /// (~10s), mirroring how streaming apps warm only the start of
        /// the next track instead of prefetching it end-to-end.
        let item: AVPlayerItem
        let preparedAt: Date
        var isReady = false

        init(
            trackID: String,
            url: URL,
            asset: AVURLAsset,
            item: AVPlayerItem,
            preparedAt: Date = Date()
        ) {
            self.trackID = trackID
            self.url = url
            self.asset = asset
            self.item = item
            self.preparedAt = preparedAt
        }
    }

    /// Observers mirror track identity / source / play state into `highlight`
    /// so list rows never have to observe the player itself (see
    /// `syncHighlight`).
    @Published private(set) var queue: [Track] = [] {
        didSet {
            syncHighlight()
            if PlaybackPreloadPolicy.hasQueueChanged(oldValue, queue) {
                invalidatePreloadedPlayback()
            }
        }
    }
    @Published private(set) var currentIndex: Int? {
        didSet { syncHighlight() }
    }
    @Published private(set) var queueSource: QueueSource? {
        didSet { syncHighlight() }
    }
    @Published private(set) var queueSeedTrackTitle: String?
    /// Active mix radio ordering. Owned here because it describes the
    /// live queue: every surface offering the control (mix hub, queue
    /// sheet) reads one value instead of keeping its own `@State`, which
    /// let two pickers disagree about the current ordering.
    @Published private(set) var mixRadioMode: MixRadioMode = .balanced
    @Published private(set) var isPlaying = false {
        didSet { syncHighlight() }
    }
    @Published private(set) var isBuffering = false
    /// Exact transport clock. Not `@Published` — UI observes `progress` so
    /// catalog/library EnvironmentObject consumers are not invalidated at 2 Hz.
    private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Shuffle mode of the queue that is playing right now.
    @Published private(set) var shuffleEnabled: Bool
    @Published private(set) var repeatMode: RepeatMode
    @Published private(set) var sleepTimerEndDate: Date?
    /// Active sleep-timer mode. Minutes keep `sleepTimerEndDate` for the
    /// countdown UI; end-of-track / end-of-queue are event-driven and
    /// leave the date nil.
    @Published private(set) var sleepTimerMode: SleepTimerMode?
    @Published var isPlayerPresented = false
    /// One-shot sheet request honored by `PlayerView` after presentation.
    @Published var pendingPlayerSheet: PendingPlayerSheet?
    @Published var errorMessage: String?

    /// Scrubber / mini-player / lyrics clock (see `PlaybackProgressModel`).
    let progress = PlaybackProgressModel()
    /// Row highlight state for catalog / library lists
    /// (see `PlaybackHighlightModel`).
    let highlight = PlaybackHighlightModel()

    /// The queue as its source handed it over, before shuffle reordered it.
    /// Turning shuffle off replays this order (see `PlaybackShuffleOrder`).
    private var sourceOrderedQueue: [Track] = []

    /// What the player's shuffle control is set to, which is not the same
    /// thing as `shuffleEnabled`: per-collection «Перемешать» shuffles the
    /// queue it starts without changing the preference, so the next queue
    /// built from a visible list still plays in that list's order.
    private var shufflePreference: Bool

    private var player = AVPlayer()
    private let nowPlaying = NowPlayingController()
    private let equalizer = EqualizerDSP()
    private let historyStore: ListeningHistoryStore
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var remoteCommandTokens: [Any] = []
    private var sleepTask: Task<Void, Never>?
    private var streamUserAgent: String?
    private var itemStatusObservation: NSKeyValueObservation?
    /// The item a `.failed` transition has already been reported for.
    ///
    /// AVFoundation can deliver the `.status == .failed` KVO change and the
    /// `AVPlayerItemFailedToPlayToEndTime` notification for the very same
    /// underlying error on the very same item. Without this guard both
    /// call `handleItemFailure`, double-spending the same-track retry
    /// budget on a single real failure and advancing the queue twice as
    /// eagerly as `StreamFailureRetryPolicy` intends.
    private var lastFailedItemIdentifier: ObjectIdentifier?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var defaultContinuationProvider: (() async throws -> [Track])?
    private var activeContinuationProvider: (() async throws -> [Track])?
    private var activeContinuationPrefetchProvider:
        (() async throws -> [Track])?
    private var streamRefreshProvider: ((Track) async throws -> Track)?
    private var offlineURLProvider: ((Track) -> URL?)?
    private var offlineInvalidationHandler: ((Track) -> Void)?
    private var offlinePlayedHandler: ((Track) -> Void)?
    private var playbackReadyHandler: ((Track, Bool) -> Void)?
    private var loadedOfflineTrackID: String?
    private var listenedTrackID: String?
    private var listenedPlaybackDuration: TimeInterval = 0
    private var lastListeningElapsedTime: TimeInterval?
    private var continuationTask: Task<Void, Never>?
    private var continuationPrefetchTask: Task<Void, Never>?
    private var advanceAfterContinuationPrefetch = false
    /// Tracks whether the queue is inside the near-end window for cancellation
    /// bookkeeping. Refills are allowed to chain while the upcoming window is
    /// still short so tiny VK pages do not leave radio dry.
    private var continuationPrefetchInThreshold = false
    private var streamRefreshTask: Task<Void, Never>?
    private var lastPersistedSecond = -1
    private var playbackGeneration = 0
    private var continuationGeneration = 0
    private var streamRefreshGeneration = 0
    private var requiresStreamRefresh = false
    private var didAttemptStreamRefresh = false
    private var audioSessionConfigured = false
    private var restoredTrackIDs = Set<String>()
    private var loadedTrackID: String?
    private var resumeOnBluetoothConnection = true
    private var pauseAtMinimumVolume = true
    private var advanceOnPlaybackError = true
    private var preferHighQuality = true
    /// Optional filter applied to mix queue fills (local dislike memory).
    private var mixTrackFilter: (([Track]) -> [Track])?
    /// Optional server-backed refill for closerToSeed / moreNovel modes.
    private var mixRadioRefillProvider:
        ((Track, MixRadioMode) async throws -> [Track])?
    private var mixRadioRefillTask: Task<Void, Never>?
    private var mixRadioRefillGeneration = 0
    /// Track IDs inserted via `playNext` — preserved across radio refills.
    private var pinnedPlayNextIDs = Set<String>()
    private var lastNowPlayingSecond = -1
    private var playbackIntended = false
    private var pausedForMinimumVolume = false
    private var pausedForAppVolumeZero = false
    private var minimumVolumeResumeSuppressed = false
    private var wasPlayingBeforeInterruption = false
    private var isAudioInterrupted = false
    private var resumeAfterRouteTransfer = false
    private var routeDisconnectPending = false
    private var outputsAtInterruptionBegan: [AVAudioSession.Port] = []
    private var interruptionBeganAt: Date?
    /// iOS 17 tells us an interruption *is* the route disconnecting, which
    /// is how Automatic Ear Detection arrives while the AirPods stay the
    /// current route.
    private var interruptionBeganAsRouteDisconnect = false
    /// Whether a call, Siri or another app owned the output when the
    /// interruption began — the one thing ear detection never looks like.
    private var otherAudioAtInterruptionBegan = false
    private var interruptionResumeTask: Task<Void, Never>?
    private var routeSettleTask: Task<Void, Never>?
    private var pendingRemoteCommand: RemoteCommandCoalescing.Command?
    private var remoteCommandFlushTask: Task<Void, Never>?
    private var lastPersistedQueueSignature = ""
    private var suppressAdvanceUntil: Date?
    private var streamRecoveryAttempts = 0
    private var streamRecoveryTask: Task<Void, Never>?
    private var stallStartedAt: Date?
    /// When `recoverFromExtendedStall` first found an existing
    /// recovery/refresh task blocking it. Cleared once no task is in the
    /// way; used to detect a task orphaned by an early-return guard clause
    /// elsewhere so the stall guard cannot wedge shut forever.
    private var extendedStallGuardBlockedSince: Date?
    private var sessionActivationRetryTask: Task<Void, Never>?
    private var sessionActivationRetryAttempts = 0
    private var preloadedPlayback: PreloadedPlayback?
    private var preloadAssetTask: Task<Void, Never>?
    private var preloadGeneration = 0
    private var preloadStreamRefreshTask: Task<Void, Never>?
    private var preloadStreamRefreshTrackID: String?
    private var preloadStreamRefreshID: UUID?
    private var attemptedPreloadRefreshes = Set<String>()
    private var canPreloadPlayback: () -> Bool = { true }
    private var artworkPrefetchHandler: (([Track]) async -> Void)?
    private var artworkPrefetchTask: Task<Void, Never>?
    /// Last condition `AppEnvironment` pushed from `NetworkMonitor`.
    /// Read by `makePlaybackItem`/`takePreloadedPlayback` when sizing a
    /// new `AVPlayerItem`'s forward buffer, and by the same-track
    /// retry path when sizing its connectivity budget/backoff — never
    /// by an item already playing, which keeps whatever buffer
    /// AVFoundation already negotiated.
    private var currentNetworkCondition: NetworkCondition = .nominal

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    /// Single place that pushes track identity / source / play state to
    /// `highlight`. Driven by the `queue`, `currentIndex`, `queueSource` and
    /// `isPlaying` observers, so every path (play, skip, queue edits, restore,
    /// stop) stays in sync.
    private func syncHighlight() {
        highlight.update(
            currentTrackID: currentTrack?.id,
            isPlaying: isPlaying,
            queueSource: queueSource
        )
    }

    /// Human-readable label for what's currently queued, shown under
    /// "СЕЙЧАС ИГРАЕТ" in the full-screen player in place of a bare
    /// "N of M" position (that position now lives in the queue screen).
    var queueContextTitle: String {
        switch queueSource {
        case let .mix(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .playlist(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .album(title) where QueueSourceTitle.isUsable(title):
            return title
        case .history:
            return L10n.text("История прослушивания")
        case .library:
            return L10n.text("Ваши треки")
        default:
            if let seed = queueSeedTrackTitle,
               QueueSourceTitle.isUsable(seed) {
                return L10n.format("Микс по «%@»", seed)
            }
            return L10n.text("Ваша очередь")
        }
    }

    func presentPlayer() {
        guard !isPlayerPresented else { return }
        isPlayerPresented = true
    }

    /// Present the full-screen player and open the queue sheet.
    func presentQueue() {
        pendingPlayerSheet = .queue
        isPlayerPresented = true
    }

    func consumePendingPlayerSheet() -> PendingPlayerSheet? {
        let sheet = pendingPlayerSheet
        pendingPlayerSheet = nil
        return sheet
    }

    func dismissPlayer() {
        guard isPlayerPresented else { return }
        isPlayerPresented = false
        pendingPlayerSheet = nil
    }

    init(
        settings: AppSettings,
        historyStore: ListeningHistoryStore,
        userAgent: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.streamUserAgent = userAgent
        resumeOnBluetoothConnection = settings.resumeOnBluetoothConnection
        pauseAtMinimumVolume = settings.pauseAtMinimumVolume
        // Playback level follows hardware / CarKit volume. Keep AVPlayer at
        // unity so the system volume slider is the only attenuation.
        advanceOnPlaybackError = settings.advanceOnPlaybackError
        preferHighQuality = settings.preferHighQuality
        shufflePreference = PlaybackShufflePreference.resolve(
            defaults: defaults
        )
        shuffleEnabled = shufflePreference
        repeatMode = RepeatMode(
            rawValue: defaults.string(forKey: "player.repeat") ?? ""
        ) ?? .off
        configurePlayerInstance()
        _ = configureAudioSession()
        updateOutputToneProfile(reloadIfNeeded: false)
        configureRemoteCommands()
        observePlayer()
        Publishers.CombineLatest4(
            settings.$equalizerEnabled,
            settings.$equalizerGains,
            settings.$equalizerPreamp,
            settings.$loudnessNormalization
        )
        .combineLatest(
            Publishers.CombineLatest3(
                settings.$dynamicRangeCompression,
                settings.$spatialAudioEnabled,
                settings.$spatialAudioIntensity
            )
        )
            // Slider drags publish on nearly every UI frame; rebuilding
            // biquad coefficients (sin/cos/pow under the same lock the
            // real-time audio tap uses) at that rate burns CPU for no
            // audible benefit, so coalesce to the latest value.
            .throttle(
                for: .milliseconds(80),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] equalizerSettings, effectsSettings in
                let (enabled, gains, preamp, loudness) = equalizerSettings
                let (drc, spatialAudio, spatialIntensity) = effectsSettings
                guard let self else { return }
                let requiredTap = self.equalizer.requiresAudioTap
                self.equalizer.update(
                    enabled: enabled,
                    gains: gains,
                    preamp: preamp,
                    loudnessNorm: loudness,
                    dynamicRangeCompression: drc,
                    spatialAudio: spatialAudio,
                    spatialIntensity: spatialIntensity
                )
                let requiresAudioTap = self.equalizer.requiresAudioTap
                self.player.allowsExternalPlayback = AudioProcessingRoutePolicy
                    .allowsExternalPlayback(
                        requiresAudioTap: requiresAudioTap
                    )
                if requiredTap != requiresAudioTap,
                   self.player.currentItem != nil {
                    self.reloadCurrentItemForAudioProcessing()
                }
            }
            .store(in: &cancellables)
        settings.$resumeOnBluetoothConnection
            .sink { [weak self] enabled in
                self?.resumeOnBluetoothConnection = enabled
            }
            .store(in: &cancellables)
        settings.$pauseAtMinimumVolume
            .sink { [weak self] enabled in
                guard let self else { return }
                self.pauseAtMinimumVolume = enabled
                self.handleOutputVolume(
                    AVAudioSession.sharedInstance().outputVolume
                )
            }
            .store(in: &cancellables)
        settings.$advanceOnPlaybackError
            .sink { [weak self] enabled in
                self?.advanceOnPlaybackError = enabled
            }
            .store(in: &cancellables)
        settings.$preferHighQuality
            .sink { [weak self] enabled in
                guard let self else { return }
                self.preferHighQuality = enabled
                self.applyStreamQualityPreference()
            }
            .store(in: &cancellables)
        restorePlayback()
    }

    func configureContinuation(
        _ provider: @escaping () async throws -> [Track]
    ) {
        cancelContinuation()
        defaultContinuationProvider = provider
        activeContinuationProvider = provider
        activeContinuationPrefetchProvider = nil
    }

    func configureMixTrackFilter(
        _ filter: @escaping ([Track]) -> [Track]
    ) {
        mixTrackFilter = filter
    }

    func configureMixRadioRefill(
        _ provider: @escaping (Track, MixRadioMode) async throws -> [Track]
    ) {
        mixRadioRefillProvider = provider
    }

    func configureStreamRefresh(
        _ provider: @escaping (Track) async throws -> Track
    ) {
        streamRefreshProvider = provider
    }

    func configurePreloading(
        isAllowed: @escaping () -> Bool,
        artworkPrefetch: @escaping ([Track]) async -> Void
    ) {
        canPreloadPlayback = isAllowed
        artworkPrefetchHandler = artworkPrefetch
        scheduleNeighborPreloads()
    }

    func cancelPreloading() {
        invalidatePreloadedPlayback()
        preloadStreamRefreshTask?.cancel()
        preloadStreamRefreshTask = nil
        preloadStreamRefreshTrackID = nil
        preloadStreamRefreshID = nil
        artworkPrefetchTask?.cancel()
        artworkPrefetchTask = nil
    }

    func resumePreloading() {
        scheduleNeighborPreloads()
    }

    func configureOfflinePlayback(
        lookup: @escaping (Track) -> URL?,
        invalidate: @escaping (Track) -> Void,
        markPlayed: @escaping (Track) -> Void
    ) {
        offlineURLProvider = lookup
        offlineInvalidationHandler = invalidate
        offlinePlayedHandler = markPlayed
    }

    func configurePlaybackReady(
        _ handler: @escaping (Track, Bool) -> Void
    ) {
        playbackReadyHandler = handler
    }

    func configureNetwork(userAgent: String?) {
        let cleaned = userAgent?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        streamUserAgent = cleaned?.isEmpty == false ? cleaned : nil
        invalidatePreloadedPlayback()
        scheduleNeighborPreloads()
    }

    /// Pushed by `AppEnvironment` whenever `NetworkMonitor` reports a new
    /// state/transport, so a 4G→3G collapse widens the buffer/retry
    /// budget the *next* item created requests instead of leaving the
    /// player pinned to the wifi numbers.
    ///
    /// - Parameter throughputHint: reserved for a future C-computed
    ///   buffer-health estimate (see `BufferHealthEstimator`, Agent D).
    ///   Unused today and safe to leave `nil` indefinitely — this is
    ///   the hook D's estimator will feed once it lands.
    func updateNetworkCondition(
        _ condition: NetworkCondition,
        throughputHint: Double? = nil
    ) {
        currentNetworkCondition = condition
    }

    /// Starts `tracks` at `track`.
    ///
    /// With shuffle off the queue *is* the collection, in the order it was
    /// handed over, positioned on the tapped track — that is the contract
    /// Медиатека depends on.
    func play(
        _ track: Track,
        in tracks: [Track],
        continuation: (() async throws -> [Track])? = nil,
        prefetchContinuation: (() async throws -> [Track])? = nil,
        source: QueueSource? = nil,
        shuffle intent: PlaybackShuffleIntent = .followPreference
    ) {
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
        cancelContinuation()
        cancelMixRadioRefill()
        pinnedPlayNextIDs.removeAll()
        cancelStreamRefresh()
        cancelStreamRecovery()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        streamRecoveryAttempts = 0
        stallStartedAt = nil
        restoredTrackIDs.removeAll()
        attemptedPreloadRefreshes.removeAll()
        activeContinuationProvider =
            continuation ?? defaultContinuationProvider
        activeContinuationPrefetchProvider = prefetchContinuation
        queueSource = source
        queueSeedTrackTitle = track.title
        // A fresh queue arrives in source order, so a previous radio
        // ranking no longer describes it — reset so the control never
        // advertises an ordering the queue does not have.
        mixRadioMode = .balanced
        let prepared = PlaybackQueueBuilder.normalized(
            selected: track,
            tracks: tracks
        )
        // A new queue starts in the mode its caller asked for. Without this
        // one «Перемешать» on an album left every later library tap
        // shuffled for the rest of the session.
        shuffleEnabled = intent == .shuffleCollection || shufflePreference
        // Snapshot the order the collection arrived in before anything
        // reorders it, so switching shuffle off restores «по очереди».
        sourceOrderedQueue = prepared
        if shuffleEnabled {
            queue = PlaybackShuffleOrder.shuffled(prepared, keeping: track)
            currentIndex = 0
        } else {
            queue = prepared
            currentIndex = prepared.firstIndex {
                $0.id == track.id
            } ?? 0
        }
        // Drop locally disliked mix tracks before ranking so bans survive
        // a fresh play() of the same stream.
        if case .mix = source, let filter = mixTrackFilter {
            let seedID = track.id
            let cleaned = filter(queue)
            if cleaned.contains(where: { $0.id == seedID }) {
                queue = cleaned
            } else {
                queue = [track] + cleaned.filter { $0.id != seedID }
            }
            currentIndex = queue.firstIndex { $0.id == seedID } ?? 0
        }
        // Mix queues from VK often cluster the same artists. Apply
        // balanced radio diversity up front so «Баланс» is not a no-op
        // that leaves the original clustered order.
        if case .mix = source, !shuffleEnabled,
           let index = currentIndex {
            let historyArtists = Set(
                historyStore.entries.prefix(40).map(\.track.artist)
            )
            queue = MixQueueRanker.rerank(
                queue: queue,
                currentIndex: index,
                seed: track,
                mode: .balanced,
                historyArtists: historyArtists
            )
        }
        resetProgressForTrackTransition()
        persistPlayback()
        continuationPrefetchInThreshold = false
        loadCurrentAndPlay()
        maybeStartContinuationPrefetch()
    }

    /// Starts a collection with shuffle on — for album/playlist detail
    /// «Перемешать» without opening the full-screen player first.
    ///
    /// Deliberately touches neither `player.shuffle` nor the in-memory
    /// preference: this is a per-collection entry point, and letting it set
    /// the preference latched shuffle on for every later queue, including
    /// Медиатека. The queue it starts still reports itself as shuffled, so
    /// the control is honest and one tap turns it off.
    func playShuffled(
        in tracks: [Track],
        continuation: (() async throws -> [Track])? = nil,
        prefetchContinuation: (() async throws -> [Track])? = nil,
        source: QueueSource? = nil
    ) {
        guard let seed = tracks.randomElement() ?? tracks.first else {
            return
        }
        play(
            seed,
            in: tracks,
            continuation: continuation,
            prefetchContinuation: prefetchContinuation,
            source: source,
            shuffle: .shuffleCollection
        )
    }

    func playNext(_ track: Track) {
        guard let currentIndex, let currentTrack else {
            play(track, in: [track])
            return
        }
        guard track.id != currentTrack.id else { return }
        cancelContinuation()
        cancelMixRadioRefill()
        queue.removeAll { $0.id == track.id }
        let adjustedCurrentIndex = queue.firstIndex {
            $0.id == currentTrack.id
        } ?? min(currentIndex, max(queue.count - 1, 0))
        self.currentIndex = adjustedCurrentIndex
        queue.insert(
            track,
            at: min(adjustedCurrentIndex + 1, queue.count)
        )
        pinnedPlayNextIDs.insert(track.id)
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index),
              let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        cancelContinuation()
        cancelMixRadioRefill()
        let removesCurrentTrack = index == currentIndex
        let shouldResume = isPlaying
        let removedTrack = queue[index]
        queue.remove(at: index)
        restoredTrackIDs.remove(removedTrack.id)
        pinnedPlayNextIDs.remove(removedTrack.id)

        guard !queue.isEmpty else {
            stop()
            return
        }

        if index < currentIndex {
            self.currentIndex = currentIndex - 1
        } else if removesCurrentTrack {
            self.currentIndex = min(currentIndex, queue.count - 1)
        }

        if removesCurrentTrack {
            cancelStreamRefresh()
            requiresStreamRefresh = false
            didAttemptStreamRefresh = false
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrent(autoplay: shouldResume, startAt: 0)
        } else {
            persistPlayback()
            publishNowPlayingQueue()
            scheduleNeighborPreloads()
        }
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = true
        cancelContinuation()
        cancelMixRadioRefill()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        currentIndex = index
        prunePinnedPlayNextIDs()
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func toggleShuffle() {
        cancelContinuation()
        cancelMixRadioRefill()
        shuffleEnabled.toggle()
        // The control is the only thing that may change the preference.
        shufflePreference = shuffleEnabled
        PlaybackShufflePreference.store(shuffleEnabled, in: defaults)
        guard let currentTrack else { return }
        if shuffleEnabled {
            // Remember what the queue looked like before this shuffle, not
            // just what `play()` started with: turning shuffle off has to
            // undo exactly this reorder.
            sourceOrderedQueue = queue
            queue = PlaybackShuffleOrder.shuffled(
                queue,
                keeping: currentTrack
            )
            currentIndex = 0
        } else {
            queue = PlaybackShuffleOrder.restored(
                queue: queue,
                sourceOrder: sourceOrderedQueue
            )
            currentIndex = queue.firstIndex { $0.id == currentTrack.id } ?? 0
        }
        pinnedPlayNextIDs.removeAll()
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        defaults.set(repeatMode.rawValue, forKey: "player.repeat")
        scheduleNeighborPreloads()
    }

    func scheduleSleepTimer(minutes: Int) {
        scheduleSleepTimer(.afterMinutes(minutes))
    }

    func scheduleSleepTimer(_ mode: SleepTimerMode) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerMode = mode
        switch mode {
        case let .afterMinutes(minutes):
            let seconds = max(minutes, 1) * 60
            sleepTimerEndDate = Date().addingTimeInterval(
                TimeInterval(seconds)
            )
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.pause()
                self?.clearSleepTimerState()
            }
        case .endOfTrack, .endOfQueue:
            sleepTimerEndDate = nil
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        clearSleepTimerState()
    }

    private func clearSleepTimerState() {
        sleepTimerEndDate = nil
        sleepTimerMode = nil
    }

    /// Whether an active end-of-queue timer should stop instead of
    /// advancing (or fetching a continuation) past the last track.
    private var shouldStopForEndOfQueueTimer: Bool {
        guard sleepTimerMode == .endOfQueue else { return false }
        guard let currentIndex, !queue.isEmpty else { return true }
        if repeatMode == .all { return false }
        return queue.index(after: currentIndex) >= queue.endIndex
    }

    func playPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        resume(
            preservingMinimumVolumePause: false,
            preservingAppVolumePause: false
        )
    }

    private func resume(
        preservingMinimumVolumePause: Bool,
        preservingAppVolumePause: Bool
    ) {
        if !preservingMinimumVolumePause {
            pausedForMinimumVolume = false
            minimumVolumeResumeSuppressed = false
        }
        if !preservingAppVolumePause {
            pausedForAppVolumeZero = false
        }
        playbackIntended = true
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        // While another app still owns the session, keep transfer intent so a
        // later interruption-end / route settle can resume. Clearing the flags
        // here used to drop CarKit / BT reconnect resumes permanently.
        guard !isAudioInterrupted else {
            resumeAfterRouteTransfer = true
            return
        }
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        if requiresStreamRefresh {
            refreshCurrentStream(autoplay: true)
            return
        }
        guard player.currentItem != nil else {
            loadCurrentAndPlay()
            return
        }
        if duration > 0, elapsedTime >= duration - 0.25 {
            seek(to: 0)
        }
        guard activateAudioSession() else { return }
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        player.volume = 1
        player.play()
        isPlaying = true
        publishPlaybackState(force: true)
        handleOutputVolume(
            AVAudioSession.sharedInstance().outputVolume
        )
    }

    func pause() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        advanceAfterContinuationPrefetch = false
        minimumVolumeResumeSuppressed = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = false
        // A pause from the user, the buds or the lock screen outranks any
        // resume still waiting on a route to settle.
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        routeSettleTask?.cancel()
        routeSettleTask = nil
        pausePreservingIntent()
    }

    /// Soft pause used while preparing a share export so AVFoundation media
    /// services are free for `AVAssetReader` without clearing the user's
    /// intent to keep listening afterwards.
    func pauseForShareExport() {
        pausePreservingIntent()
    }

    /// Whether playback the app starts on its own may begin right now —
    /// see `AudioAutoplayGatePolicy`.
    private var allowsAutomaticPlayback: Bool {
        AudioAutoplayGatePolicy.allowsAutomaticPlayback(
            routeDisconnectPending: routeDisconnectPending,
            currentOutputPortTypes: AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
        )
    }

    private func pausePreservingIntent() {
        player.pause()
        isPlaying = false
        publishPlaybackState(force: true)
    }

    func next() {
        guard let currentIndex, !queue.isEmpty else { return }
        let nextIndex = queue.index(after: currentIndex)
        if nextIndex >= queue.endIndex, repeatMode == .off {
            if sleepTimerMode == .endOfQueue {
                cancelSleepTimer()
                pause()
                return
            }
            if continuationPrefetchTask != nil {
                advanceAfterContinuationPrefetch = true
                isBuffering = true
                return
            }
            startContinuationIfNeeded()
            return
        }
        cancelContinuation()
        cancelMixRadioRefill()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        self.currentIndex = nextIndex < queue.endIndex ? nextIndex : 0
        prunePinnedPlayNextIDs()
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func previous() {
        if elapsedTime > 4 {
            seek(to: 0)
            return
        }
        guard let currentIndex, !queue.isEmpty else { return }
        cancelContinuation()
        cancelMixRadioRefill()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        if currentIndex > 0 {
            self.currentIndex = currentIndex - 1
        } else {
            self.currentIndex = repeatMode == .all ? queue.count - 1 : 0
        }
        prunePinnedPlayNextIDs()
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
    }

    func seek(to seconds: TimeInterval) {
        let upperBound = duration > 0 ? duration : seconds
        let targetSeconds = min(max(0, seconds), upperBound)
        lastListeningElapsedTime = targetSeconds
        let target = CMTime(
            seconds: targetSeconds,
            preferredTimescale: 600
        )
        let isOffline = loadedOfflineTrackID != nil
            && loadedOfflineTrackID == currentTrack?.id
        let tolerance = PlaybackSeekTolerancePolicy.tolerance(
            isOffline: isOffline
        )
        player.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        updateElapsedTime(targetSeconds, forceProgressPublish: true)
        persistPlayback()
        publishPlaybackState(force: true)
    }

    func stop() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        playbackIntended = false
        playbackGeneration += 1
        dismissPlayer()
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        routeSettleTask?.cancel()
        routeSettleTask = nil
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        sessionActivationRetryAttempts = 0
        extendedStallGuardBlockedSince = nil
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEndDate = nil
        sleepTimerMode = nil
        cancelContinuation()
        cancelMixRadioRefill()
        pinnedPlayNextIDs.removeAll()
        cancelStreamRefresh()
        cancelPreloading()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        lastFailedItemIdentifier = nil
        queue = []
        sourceOrderedQueue = []
        currentIndex = nil
        queueSource = nil
        queueSeedTrackTitle = nil
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        listenedTrackID = nil
        listenedPlaybackDuration = 0
        lastListeningElapsedTime = nil
        updateElapsedTime(0, forceProgressPublish: true)
        duration = 0
        isPlaying = false
        isBuffering = false
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        restoredTrackIDs.removeAll()
        nowPlaying.clear()
        lastNowPlayingSecond = -1
        lastPersistedQueueSignature = ""
        defaults.removeObject(forKey: PlaybackSnapshot.key)
        defaults.removeObject(forKey: PlaybackSnapshot.elapsedKey)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func loadCurrentAndPlay() {
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        playbackIntended = true
        if let track = currentTrack,
           restoredTrackIDs.contains(track.id),
           offlineURLProvider?(track) == nil {
            requiresStreamRefresh = true
            didAttemptStreamRefresh = false
            refreshCurrentStream(autoplay: true)
            return
        }
        loadCurrent(autoplay: true, startAt: 0)
    }

    /// - Parameter automatic: `true` when the app is starting playback of
    ///   its own accord — a retry, a stall recovery, a reload after media
    ///   services died. Such a start waits for a route while the
    ///   headphones that were playing are gone, so it cannot land on the
    ///   built-in speaker; a start the user asked for never waits.
    private func loadCurrent(
        autoplay requestedAutoplay: Bool,
        startAt position: TimeInterval,
        automatic: Bool = false
    ) {
        let autoplay = requestedAutoplay
            && (!automatic || allowsAutomaticPlayback)
        if requestedAutoplay, !autoplay {
            // Held back by the gate, not given up on: the next route the
            // user connects picks the track back up.
            resumeAfterRouteTransfer = playbackIntended
        }
        guard let track = currentTrack else { return }
        let offlineURL = offlineURLProvider?(track)
        guard let url = offlineURL ?? track.streamURL else {
            if streamRefreshProvider != nil {
                streamRecoveryAttempts += 1
                if StreamFailureRetryPolicy.shouldRetrySameTrack(
                    attempts: streamRecoveryAttempts,
                    error: APIError.timedOut,
                    condition: currentNetworkCondition
                ) {
                    scheduleSameTrackRecovery(
                        autoplay: autoplay,
                        automatic: true
                    )
                    return
                }
                if StreamFailureRetryPolicy.shouldAdvance(
                    attempts: streamRecoveryAttempts,
                    error: APIError.invalidResponse,
                    advanceOnPlaybackError: advanceOnPlaybackError
                ),
                   advancePastFailedTrackIfPossible() {
                    return
                }
            }
            loadedTrackID = track.id
            updateElapsedTime(0, forceProgressPublish: true)
            duration = track.duration
            errorMessage = L10n.text(
                "Для этого трека отсутствует доступный аудиопоток."
            )
            isPlaying = false
            nowPlaying.update(
                track: track,
                elapsedTime: 0,
                rate: 0,
                queueCount: queue.count,
                queueIndex: currentIndex ?? 0
            )
            return
        }
        errorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        let isOffline = offlineURL != nil
        let item = takePreloadedPlayback(for: track, url: url)
            ?? makePlaybackItem(url: url, isOffline: isOffline)
        let wantsAudioTap = equalizer.requiresAudioTap
            && AudioProcessingAttachPolicy.supportsAudioTap(
                url: url,
                isOffline: isOffline
            )
        player.allowsExternalPlayback = AudioProcessingRoutePolicy
            .allowsExternalPlayback(requiresAudioTap: wantsAudioTap)
        // Defer mix attach until tracks exist (readyToPlay). Premature
        // AVAudioMix on remote progressive / empty-track assets fails the
        // item — especially after CarKit media-services resets.
        item.audioMix = nil
        itemStatusObservation?.invalidate()
        lastFailedItemIdentifier = nil
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self,
                      generation == self.playbackGeneration,
                      self.player.currentItem === item else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.streamRecoveryAttempts = 0
                    self.didAttemptStreamRefresh = false
                    self.stallStartedAt = nil
                    self.lastFailedItemIdentifier = nil
                    self.cancelStreamRecovery()
                    if wantsAudioTap {
                        self.attachAudioProcessing(to: item)
                    }
                    self.playbackReadyHandler?(track, isOffline)
                    self.scheduleNeighborPreloads()
                    if position > 0 {
                        self.seek(to: min(position, self.duration))
                    }
                case .failed:
                    self.isPlaying = false
                    self.isBuffering = false
                    let identifier = ObjectIdentifier(item)
                    guard self.lastFailedItemIdentifier != identifier else {
                        return
                    }
                    self.lastFailedItemIdentifier = identifier
                    self.handleItemFailure(item.error)
                case .unknown:
                    self.isBuffering = true
                @unknown default:
                    self.isBuffering = false
                }
            }
        }
        player.replaceCurrentItem(with: item)
        loadedTrackID = track.id
        loadedOfflineTrackID = isOffline ? track.id : nil
        updateElapsedTime(position, forceProgressPublish: true)
        duration = track.duration
        let shouldAutoplay = autoplay && activateAudioSession()
        if shouldAutoplay {
            pausedForMinimumVolume = false
            player.volume = 1
            player.play()
            isPlaying = true
            isBuffering = true
            handleOutputVolume(
                AVAudioSession.sharedInstance().outputVolume
            )
        } else {
            isPlaying = false
            isBuffering = false
        }
        nowPlaying.update(
            track: track,
            elapsedTime: position,
            rate: shouldAutoplay ? 1 : 0,
            queueCount: queue.count,
            queueIndex: currentIndex ?? 0
        )
        persistPlayback()
    }

    private func makePlaybackItem(
        url: URL,
        isOffline: Bool
    ) -> AVPlayerItem {
        let item = AVPlayerItem(
            asset: makePlaybackAsset(url: url, isOffline: isOffline)
        )
        item.preferredForwardBufferDuration =
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(
                for: currentNetworkCondition
            )
        item.preferredPeakBitRate = StreamQualityPolicy.preferredPeakBitRate(
            preferHighQuality: preferHighQuality
        )
        return item
    }

    private func applyStreamQualityPreference() {
        player.currentItem?.preferredPeakBitRate =
            StreamQualityPolicy.preferredPeakBitRate(
                preferHighQuality: preferHighQuality
            )
    }

    private func makePlaybackAsset(
        url: URL,
        isOffline: Bool
    ) -> AVURLAsset {
        let asset: AVURLAsset
        if isOffline {
            asset = AVURLAsset(url: url)
        } else {
            var headers = [
                "Referer": "https://vk.com/",
                "Origin": "https://vk.com"
            ]
            if let streamUserAgent {
                headers["User-Agent"] = streamUserAgent
            }
            asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
        }
        return asset
    }

    private func attachAudioProcessing(to item: AVPlayerItem) {
        item.audioMix = nil
        guard equalizer.requiresAudioTap,
              let tap = equalizer.makeTap() else {
            return
        }
        // Bind the tap to a concrete audio track — required for remote
        // progressive URLs. Empty track lists (typical HLS) mean DSP cannot
        // run; leave the item unprocessed rather than failing playback.
        let audioTrack = item.tracks
            .compactMap(\.assetTrack)
            .first { $0.mediaType == .audio }
        guard let audioTrack else {
            player.allowsExternalPlayback = AudioProcessingRoutePolicy
                .allowsExternalPlayback(requiresAudioTap: false)
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func scheduleNeighborPreloads() {
        maybeStartContinuationPrefetch()
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let remotePreloadingAllowed = canPreloadPlayback()
        if !lowPowerMode, remotePreloadingAllowed {
            prefetchNeighborArtwork()
        } else {
            artworkPrefetchTask?.cancel()
            artworkPrefetchTask = nil
        }
        guard !lowPowerMode,
              let nextIndex = PlaybackPreloadPolicy.nextIndex(
                queueCount: queue.count,
                currentIndex: currentIndex,
                repeatMode: repeatMode
              ),
              queue.indices.contains(nextIndex) else {
            invalidatePreloadedPlayback()
            return
        }
        let track = queue[nextIndex]
        if let refreshTrackID = preloadStreamRefreshTrackID,
           refreshTrackID != track.id {
            preloadStreamRefreshTask?.cancel()
            preloadStreamRefreshTask = nil
            preloadStreamRefreshTrackID = nil
            preloadStreamRefreshID = nil
        }
        let offlineURL = offlineURLProvider?(track)
        guard (offlineURL != nil || remotePreloadingAllowed),
              offlineURL != nil || !restoredTrackIDs.contains(track.id),
              let url = offlineURL ?? track.streamURL else {
            invalidatePreloadedPlayback()
            return
        }
        if let existing = preloadedPlayback,
           PlaybackPreloadPolicy.isValid(
            trackID: track.id,
            url: url,
            preparedTrackID: existing.trackID,
            preparedURL: existing.url,
            preparedAt: existing.preparedAt
           ) {
            return
        }

        invalidatePreloadedPlayback()
        let asset = makePlaybackAsset(
            url: url,
            isOffline: offlineURL != nil
        )
        let item = AVPlayerItem(asset: asset)
        // Streaming-service-style preload: warm only the first ~10s of
        // the next track so skip / auto-advance feels instant, without
        // downloading (and holding in memory) the whole file the way a
        // full prefetch would.
        item.preferredForwardBufferDuration =
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: false,
                condition: currentNetworkCondition
            )
        let slot = PreloadedPlayback(
            trackID: track.id,
            url: url,
            asset: asset,
            item: item
        )
        preloadedPlayback = slot
        preloadGeneration += 1
        let generation = preloadGeneration
        preloadAssetTask = Task { [weak self] in
            do {
                let isPlayable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard let self,
                      generation == self.preloadGeneration,
                      self.preloadedPlayback === slot else {
                    return
                }
                self.preloadAssetTask = nil
                if isPlayable {
                    slot.isReady = true
                } else {
                    self.recoverPreloadAfterFailure(slot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.preloadGeneration,
                      self.preloadedPlayback === slot else {
                    return
                }
                self.preloadAssetTask = nil
                self.recoverPreloadAfterFailure(slot)
            }
        }
    }

    private func takePreloadedPlayback(
        for track: Track,
        url: URL
    ) -> AVPlayerItem? {
        guard let slot = preloadedPlayback,
              slot.isReady,
              PlaybackPreloadPolicy.isValid(
                trackID: track.id,
                url: url,
                preparedTrackID: slot.trackID,
                preparedURL: slot.url,
                preparedAt: slot.preparedAt
              ) else {
            if preloadedPlayback != nil {
                invalidatePreloadedPlayback()
            }
            return nil
        }
        preloadGeneration += 1
        preloadAssetTask?.cancel()
        preloadAssetTask = nil
        preloadedPlayback = nil
        let item = slot.item
        // Promote from the ~10s warm-up buffer to the normal streaming
        // buffer now that this item is about to become the actively
        // playing one (see `StreamFailureRetryPolicy` for why 30s).
        item.preferredForwardBufferDuration =
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: true,
                condition: currentNetworkCondition
            )
        item.preferredPeakBitRate = StreamQualityPolicy.preferredPeakBitRate(
            preferHighQuality: preferHighQuality
        )
        return item
    }

    private func invalidatePreloadedPlayback() {
        preloadGeneration += 1
        preloadAssetTask?.cancel()
        preloadAssetTask = nil
        preloadedPlayback = nil
    }

    private func recoverPreloadAfterFailure(
        _ slot: PreloadedPlayback
    ) {
        let trackID = slot.trackID
        let failedURL = slot.url
        invalidatePreloadedPlayback()
        guard !failedURL.isFileURL,
              preloadStreamRefreshTask == nil,
              let provider = streamRefreshProvider,
              let track = queue.first(where: { $0.id == trackID }) else {
            return
        }
        let refreshKey = "\(trackID)#\(failedURL.absoluteString)"
        guard attemptedPreloadRefreshes.insert(refreshKey).inserted else {
            return
        }
        let refreshID = UUID()
        preloadStreamRefreshTrackID = trackID
        preloadStreamRefreshID = refreshID
        preloadStreamRefreshTask = Task { [weak self] in
            defer {
                if let self,
                   self.preloadStreamRefreshID == refreshID {
                    self.preloadStreamRefreshTask = nil
                    self.preloadStreamRefreshTrackID = nil
                    self.preloadStreamRefreshID = nil
                }
            }
            do {
                let refreshed = try await provider(track)
                try Task.checkCancellation()
                guard let self,
                      self.preloadStreamRefreshID == refreshID,
                      let nextIndex = PlaybackPreloadPolicy.nextIndex(
                        queueCount: self.queue.count,
                        currentIndex: self.currentIndex,
                        repeatMode: self.repeatMode
                      ),
                      self.queue.indices.contains(nextIndex),
                      self.queue[nextIndex].id == trackID else {
                    return
                }
                self.queue[nextIndex] = refreshed
                self.restoredTrackIDs.remove(trackID)
                self.persistPlayback()
                self.scheduleNeighborPreloads()
            } catch is CancellationError {
                self?.attemptedPreloadRefreshes.remove(refreshKey)
            } catch {}
        }
    }

    private func prefetchNeighborArtwork() {
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        var neighbors: [Track] = []
        if currentIndex > 0 {
            neighbors.append(queue[currentIndex - 1])
        } else if repeatMode == .all, queue.count > 1 {
            neighbors.append(queue[queue.count - 1])
        }
        if let nextIndex = PlaybackPreloadPolicy.nextIndex(
            queueCount: queue.count,
            currentIndex: currentIndex,
            repeatMode: repeatMode
        ) {
            let next = queue[nextIndex]
            if !neighbors.contains(where: { $0.id == next.id }) {
                neighbors.append(next)
            }
        }
        artworkPrefetchTask?.cancel()
        guard let artworkPrefetchHandler, !neighbors.isEmpty else {
            artworkPrefetchTask = nil
            return
        }
        artworkPrefetchTask = Task {
            await artworkPrefetchHandler(neighbors)
        }
    }

    @discardableResult
    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            if #available(iOS 17.0, *) {
                // Keep the system's expected media-app behavior when wired or
                // wireless headphones disappear: interrupt playback instead
                // of leaking audio through the device speaker.
                try? session.setPrefersInterruptionOnRouteDisconnect(true)
            }
            audioSessionConfigured = true
            return true
        } catch {
            audioSessionConfigured = false
            return false
        }
    }

    private func activateAudioSession() -> Bool {
        guard audioSessionConfigured || configureAudioSession() else {
            errorMessage = L10n.text(
                "Не удалось подготовить фоновое воспроизведение."
            )
            return false
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            sessionActivationRetryAttempts = 0
            sessionActivationRetryTask?.cancel()
            sessionActivationRetryTask = nil
            return true
        } catch {
            errorMessage = L10n.text(
                "Не удалось включить звук. Закройте другое аудиоприложение "
                    + "и повторите попытку."
            )
            scheduleSessionActivationRetry()
            return false
        }
    }

    /// A `setActive(true)` throw right after a call ends or media services
    /// reset is usually the session still winding down, not a permanent
    /// failure. Retries a bounded number of times with a small capped
    /// delay; success resumes playback if the user still wants it playing,
    /// and exhaustion leaves the error already surfaced above in place
    /// without retrying forever or crashing.
    private func scheduleSessionActivationRetry() {
        guard playbackIntended,
              SessionActivationRetryPolicy.shouldRetry(
                  attempt: sessionActivationRetryAttempts
              ) else {
            sessionActivationRetryAttempts = 0
            return
        }
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryAttempts += 1
        let delay = SessionActivationRetryPolicy.retryDelay(
            forAttempt: sessionActivationRetryAttempts
        )
        let generation = playbackGeneration
        sessionActivationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  generation == self.playbackGeneration,
                  self.playbackIntended,
                  !self.isPlaying else {
                return
            }
            self.sessionActivationRetryTask = nil
            if self.activateAudioSession() {
                self.errorMessage = nil
                self.resume()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTokens = [
            center.playCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.play)
                return .success
            },
            center.pauseCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.pause)
                return .success
            },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.toggle)
                return .success
            },
            center.nextTrackCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.next)
                return .success
            },
            center.previousTrackCommand.addTarget { [weak self] _ in
                self?.enqueueRemoteCommand(.previous)
                return .success
            },
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent
                else {
                    return .commandFailed
                }
                self?.enqueueRemoteCommand(.seek(event.positionTime))
                return .success
            }
        ]
    }

    /// Headphone / CarKit remotes often deliver pause+toggle in one burst.
    /// Coalesce on the main actor so the second command cannot undo the first.
    nonisolated private func enqueueRemoteCommand(
        _ command: RemoteCommandCoalescing.Command
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingRemoteCommand = RemoteCommandCoalescing.merge(
                pending: pendingRemoteCommand,
                incoming: command
            )
            remoteCommandFlushTask?.cancel()
            remoteCommandFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self,
                      !Task.isCancelled,
                      let command = pendingRemoteCommand else {
                    return
                }
                pendingRemoteCommand = nil
                applyRemoteCommand(command)
            }
        }
    }

    private func applyRemoteCommand(
        _ command: RemoteCommandCoalescing.Command
    ) {
        switch command {
        case .play:
            resume()
        case .pause:
            pause()
        case .toggle:
            playPause()
        case .next:
            next()
        case .previous:
            previous()
        case let .seek(time):
            seek(to: time)
        }
    }

    private func configurePlayerInstance() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1
        player.allowsExternalPlayback = AudioProcessingRoutePolicy
            .allowsExternalPlayback(
                requiresAudioTap: equalizer.requiresAudioTap
            )
    }

    private func observePlayer() {
        installPeriodicTimeObserver()

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let finishedItem = notification.object as? AVPlayerItem,
                      finishedItem === self.player.currentItem else {
                    return
                }
                self.advanceAfterCompletion()
            }
        })
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error
            Task { @MainActor in
                guard let self,
                      let failedItem = notification.object as? AVPlayerItem,
                      failedItem === self.player.currentItem else {
                    return
                }
                self.isPlaying = false
                self.isBuffering = false
                let identifier = ObjectIdentifier(failedItem)
                guard self.lastFailedItemIdentifier != identifier else {
                    return
                }
                self.lastFailedItemIdentifier = identifier
                self.handleItemFailure(error)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMediaServicesReset()
            }
        })
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleOutputVolume(
                    AVAudioSession.sharedInstance().outputVolume
                )
            }
        }
    }

    private func installPeriodicTimeObserver() {
        let observedPlayer = player
        timeObserver = observedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.player === observedPlayer,
                      self.loadedTrackID == self.currentTrack?.id,
                      self.player.currentItem != nil else {
                    return
                }
                let newElapsed = max(
                    0,
                    time.seconds.isFinite ? time.seconds : 0
                )
                self.updateElapsedTime(newElapsed)
                if let seconds = self.player.currentItem?.duration.seconds,
                   seconds.isFinite,
                   abs(self.duration - seconds) >= 0.25 {
                    self.duration = seconds
                }
                self.sampleListeningProgress()
                let buffering = self.isPlaying
                    && self.player.timeControlStatus
                        == .waitingToPlayAtSpecifiedRate
                if buffering {
                    if self.stallStartedAt == nil {
                        self.stallStartedAt = Date()
                    } else if let started = self.stallStartedAt,
                              Date().timeIntervalSince(started)
                                >= StreamFailureRetryPolicy
                                .stallRecoveryThreshold {
                        self.stallStartedAt = nil
                        self.recoverFromExtendedStall()
                    }
                } else {
                    self.stallStartedAt = nil
                }
                if self.isBuffering != buffering {
                    self.isBuffering = buffering
                }
                self.publishPlaybackState()
                let wholeSecond = Int(self.elapsedTime)
                if wholeSecond > 0,
                   wholeSecond % 15 == 0,
                   wholeSecond != self.lastPersistedSecond {
                    self.lastPersistedSecond = wholeSecond
                    self.persistPlayback()
                }
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[
            AVAudioSessionInterruptionTypeKey
        ] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }
        switch type {
        case .began:
            interruptionResumeTask?.cancel()
            interruptionResumeTask = nil
            isAudioInterrupted = true
            outputsAtInterruptionBegan = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            interruptionBeganAt = Date()
            interruptionBeganAsRouteDisconnect = Self.isRouteDisconnect(
                notification
            )
            otherAudioAtInterruptionBegan = AVAudioSession.sharedInstance()
                .isOtherAudioPlaying
            wasPlayingBeforeInterruption = playbackIntended && isPlaying
            // iOS 17 states the disconnect outright. When the route read
            // has already moved on to the phone itself, that is the whole
            // unplug in one notification, and the gate has to shut here:
            // by the time the interruption ends, the route it recorded no
            // longer names anything that could be seen to have been lost.
            if interruptionBeganAsRouteDisconnect,
               !outputsAtInterruptionBegan.contains(
                   where: AudioRoutePolicy.isExternalPlayback
               ) {
                routeDisconnectPending = true
                resumeAfterRouteTransfer = wasPlayingBeforeInterruption
            }
            pausePreservingIntent()
        case .ended:
            isAudioInterrupted = false
            let previousOutputs = outputsAtInterruptionBegan
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            let beganAt = interruptionBeganAt
            let beganAsRouteDisconnect = interruptionBeganAsRouteDisconnect
            let otherAudioWasPlaying = otherAudioAtInterruptionBegan
            interruptionBeganAt = nil
            interruptionBeganAsRouteDisconnect = false
            otherAudioAtInterruptionBegan = false
            // Taking the headphones off is the user saying stop, exactly
            // like a pause from the buds themselves: the intent goes with
            // it, so nothing later — a reconnect, a call ending, a stream
            // retry — starts the track up again on its own.
            if wasPlayingBeforeInterruption || playbackIntended,
               AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                   beganAsRouteDisconnect: beganAsRouteDisconnect,
                   otherAudioWasPlaying: otherAudioWasPlaying,
                   interruptionDuration: beganAt.map {
                       Date().timeIntervalSince($0)
                   } ?? .greatestFiniteMagnitude,
                   previousOutputPortTypes: previousOutputs,
                   currentOutputPortTypes: currentOutputs
               ) {
                interruptionResumeTask?.cancel()
                interruptionResumeTask = nil
                wasPlayingBeforeInterruption = false
                outputsAtInterruptionBegan = []
                resumeAfterRouteTransfer = false
                playbackIntended = false
                pausePreservingIntent()
                return
            }
            if AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: currentOutputs
            ) {
                routeDisconnectPending = true
                // `.oldDeviceUnavailable` may already have run and recorded
                // the intent to carry playback to the next route; the
                // interruption that came with the same unplug must not
                // erase it on the way past.
                resumeAfterRouteTransfer =
                    (wasPlayingBeforeInterruption || resumeAfterRouteTransfer)
                    && playbackIntended
                wasPlayingBeforeInterruption = false
                outputsAtInterruptionBegan = []
                handleOutputVolume(AVAudioSession.sharedInstance().outputVolume)
                return
            }
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(
                rawValue: rawOptions
            )
            let shouldResume = AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: wasPlayingBeforeInterruption,
                playbackIntended: playbackIntended,
                routeDisconnectPending: routeDisconnectPending,
                beganAsRouteDisconnect: beganAsRouteDisconnect,
                options: options
            )
            wasPlayingBeforeInterruption = false
            outputsAtInterruptionBegan = []
            if shouldResume {
                scheduleInterruptionResume(from: previousOutputs)
            } else if resumeAfterRouteTransfer,
                      playbackIntended,
                      !beganAsRouteDisconnect,
                      !routeDisconnectPending {
                scheduleInterruptionResume(from: previousOutputs)
            }
            handleOutputVolume(AVAudioSession.sharedInstance().outputVolume)
        @unknown default:
            break
        }
    }

    /// Whether the system named the route disconnecting as the reason for
    /// an interruption, which is what
    /// `setPrefersInterruptionOnRouteDisconnect(true)` asks it to do.
    private static func isRouteDisconnect(_ notification: Notification) -> Bool {
        guard #available(iOS 17.0, *),
              let raw = notification.userInfo?[
                AVAudioSessionInterruptionReasonKey
              ] as? UInt,
              let reason = AVAudioSession.InterruptionReason(rawValue: raw)
        else {
            return false
        }
        return reason == .routeDisconnected
    }

    /// Waits for the route to settle so a trailing `.oldDeviceUnavailable`
    /// can set `routeDisconnectPending` before we reactivate, then checks
    /// the route itself in case the notification is later still.
    ///
    /// - Parameter previousOutputs: the outputs playback was running on
    ///   when the interruption began. A resume that finds them gone is the
    ///   unplug arriving late, and holds for `newDeviceAvailable` instead
    ///   of restarting on the speaker.
    private func scheduleInterruptionResume(
        from previousOutputs: [AVAudioSession.Port]
    ) {
        interruptionResumeTask?.cancel()
        interruptionResumeTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(
                    AudioInterruptionPolicy.routeSettleDelay * 1_000_000_000
                )
            )
            guard !Task.isCancelled else { return }
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            guard AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: isAudioInterrupted,
                playbackIntended: playbackIntended,
                routeDisconnectPending: routeDisconnectPending,
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: currentOutputs
            ) else {
                if AudioRoutePolicy.didLoseExternalRoute(
                    previousOutputPortTypes: previousOutputs,
                    currentOutputPortTypes: currentOutputs
                ) {
                    routeDisconnectPending = true
                    resumeAfterRouteTransfer = playbackIntended
                    pausePreservingIntent()
                }
                return
            }
            resume()
        }
    }

    /// Re-reads the route after a disconnect that arrived while the session
    /// still named the device it lost.
    ///
    /// If the route has landed on the phone itself, the pause stands and
    /// the pending flag keeps automatic playback off the speaker. If a
    /// second external device took the playback over — a car head unit
    /// while AirPods went away — the transfer is honoured the same way
    /// `newDeviceAvailable` would.
    private func scheduleRouteSettleRecheck(
        from previousOutputs: [AVAudioSession.Port]
    ) {
        routeSettleTask?.cancel()
        routeSettleTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(
                    AudioInterruptionPolicy.routeSettleDelay * 1_000_000_000
                )
            )
            guard !Task.isCancelled else { return }
            let settledOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            // Nothing left to listen through: the pause stands and the
            // gate stays shut. Reading a settled built-in speaker as "no
            // loss" is what let a disconnect with no previous route in its
            // payload reopen automatic playback a third of a second later.
            guard settledOutputs.contains(
                where: AudioRoutePolicy.isExternalPlayback
            ) else {
                return
            }
            guard !AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: settledOutputs
            ) else {
                return
            }
            let pendingResume = resumeAfterRouteTransfer
            routeDisconnectPending = false
            // The route that settled is the same one the disconnect named:
            // nothing took the playback over, so nothing starts it again.
            // AirPods leaving an ear look exactly like this, and resuming
            // there is the defect this release is about.
            guard Set(settledOutputs) != Set(previousOutputs) else { return }
            guard AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: pendingResume,
                playbackIntended: playbackIntended,
                hasCurrentTrack: currentTrack != nil,
                isPlaying: isPlaying,
                resumeBluetoothEnabled: resumeOnBluetoothConnection,
                currentOutputPortTypes: settledOutputs
            ) else {
                return
            }
            resumeAfterRouteTransfer = false
            _ = activateAudioSession()
            resume()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        updateOutputToneProfile(reloadIfNeeded: true)
        guard let rawReason = notification.userInfo?[
            AVAudioSessionRouteChangeReasonKey
        ] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(
                rawValue: rawReason
              ) else {
            return
        }
        let previousOutputs = (notification.userInfo?[
            AVAudioSessionRouteChangePreviousRouteKey
        ] as? AVAudioSessionRouteDescription)?.outputs.map(\.portType) ?? []
        var allowsMinimumVolumeResume = true
        switch reason {
        case .oldDeviceUnavailable:
            if handleRouteLoss(
                previousOutputs: previousOutputs,
                acceptsStaleRoute: true
            ) {
                allowsMinimumVolumeResume = false
            }
        case .newDeviceAvailable:
            // A route has arrived, so the settle re-check has nothing left
            // to decide — this branch owns the transfer now.
            routeSettleTask?.cancel()
            routeSettleTask = nil
            let pendingResume = resumeAfterRouteTransfer
            resumeAfterRouteTransfer = false
            let currentOutputs = AVAudioSession.sharedInstance()
                .currentRoute.outputs.map(\.portType)
            if currentOutputs.contains(where: AudioRoutePolicy.isBluetooth),
               !resumeOnBluetoothConnection {
                allowsMinimumVolumeResume = false
                minimumVolumeResumeSuppressed = true
            }
            if AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: pendingResume,
                playbackIntended: playbackIntended,
                hasCurrentTrack: currentTrack != nil,
                isPlaying: isPlaying,
                resumeBluetoothEnabled: resumeOnBluetoothConnection,
                currentOutputPortTypes: currentOutputs
            ) {
                routeDisconnectPending = false
                _ = activateAudioSession()
                resume()
            } else if currentOutputs.contains(
                where: AudioRoutePolicy.isExternalPlayback
            ) {
                // Settled on an external route — speaker-leak risk is gone,
                // so do not leave `routeDisconnectPending` stuck forever
                // (it would block later call-end auto-resume).
                routeDisconnectPending = false
                _ = activateAudioSession()
            }
        default:
            // `.oldDeviceUnavailable` is the documented way a listening
            // route goes away, but it is not the only reason that carries
            // the move. Whatever the system calls it, playback that was
            // running on a route the user was listening through must never
            // land on the phone's own speaker.
            guard AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(reason),
                  handleRouteLoss(
                      previousOutputs: previousOutputs,
                      acceptsStaleRoute: false
                  ) else {
                break
            }
            allowsMinimumVolumeResume = false
        }
        handleOutputVolume(
            AVAudioSession.sharedInstance().outputVolume,
            allowsAutomaticResume: allowsMinimumVolumeResume
        )
    }

    /// Pauses and shuts the automatic-playback gate when the route
    /// playback was running on has gone away.
    ///
    /// - Parameter acceptsStaleRoute: whether a `currentRoute` that has
    ///   not caught up — one still naming the device that went away, or
    ///   one arriving with no previous route at all — counts as the
    ///   disconnect. Only `.oldDeviceUnavailable` states outright that
    ///   something was lost, so only it may act on an unsettled read.
    /// - Returns: whether a disconnect was acted on.
    @discardableResult
    private func handleRouteLoss(
        previousOutputs: [AVAudioSession.Port],
        acceptsStaleRoute: Bool
    ) -> Bool {
        let currentOutputs = AVAudioSession.sharedInstance()
            .currentRoute.outputs.map(\.portType)
        // The disconnect is recognised from the route alone. Requiring a
        // live playback flag lost the unplug whose interruption arrived
        // first: that interruption had already paused playback and cleared
        // the flag, so nothing here held the session back and the next
        // automatic resume went to the speaker.
        let lostRoute = AudioRoutePolicy.didLoseExternalRoute(
            previousOutputPortTypes: previousOutputs,
            currentOutputPortTypes: currentOutputs
        )
        let unsettledRoute = acceptsStaleRoute
            && (AudioRoutePolicy.looksLikeStaleRouteLoss(
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: currentOutputs
            ) || AudioRoutePolicy.isUnattributedRouteLoss(
                previousOutputPortTypes: previousOutputs,
                currentOutputPortTypes: currentOutputs
            ))
        guard lostRoute || unsettledRoute else { return false }
        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        let playbackWasActive = isPlaying
            || wasPlayingBeforeInterruption
            || resumeAfterRouteTransfer
        routeDisconnectPending = true
        resumeAfterRouteTransfer = playbackIntended && playbackWasActive
        // Unconditional: `isPlaying` is published state, and the route
        // notification can beat the rate change that sets it, so a
        // conditional pause is the speaker leak this whole branch exists
        // to prevent.
        pausePreservingIntent()
        // Re-read the route once it settles even when the loss looked
        // unambiguous: a head unit can take a disconnected pair of buds
        // over without a `newDeviceAvailable` of its own.
        scheduleRouteSettleRecheck(from: previousOutputs)
        return true
    }

    private func handleMediaServicesReset() {
        let wasActivelyPlaying = isPlaying
            || wasPlayingBeforeInterruption
            || resumeAfterRouteTransfer
        let shouldAutoplay = MediaServicesResetPolicy.shouldAutoplayAfterReset(
            playbackIntended: playbackIntended,
            wasActivelyPlaying: wasActivelyPlaying
        )
        let position = elapsedTime
        let keepIntent = playbackIntended || wasActivelyPlaying
        let disconnectWasPending = routeDisconnectPending
        suppressAdvanceUntil = Date().addingTimeInterval(
            AudioProcessingAttachPolicy.postResetAdvanceSuppression
        )

        interruptionResumeTask?.cancel()
        interruptionResumeTask = nil
        routeSettleTask?.cancel()
        routeSettleTask = nil
        // The session is about to be torn down and rebuilt from scratch, so
        // any bounded reactivation retry still waiting on the old session
        // would only race the rebuild below.
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        sessionActivationRetryAttempts = 0
        extendedStallGuardBlockedSince = nil
        pausedForMinimumVolume = false
        pausedForAppVolumeZero = false
        minimumVolumeResumeSuppressed = false
        isAudioInterrupted = false
        wasPlayingBeforeInterruption = false
        resumeAfterRouteTransfer = false
        routeDisconnectPending = false
        outputsAtInterruptionBegan = []
        otherAudioAtInterruptionBegan = false
        isPlaying = false
        isBuffering = false
        playbackIntended = keepIntent
        publishPlaybackState(force: true)

        cancelContinuation()
        cancelStreamRefresh()
        cancelPreloading()
        playbackGeneration += 1
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        lastFailedItemIdentifier = nil

        let orphanedPlayer = player
        if let timeObserver {
            orphanedPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        orphanedPlayer.pause()
        orphanedPlayer.replaceCurrentItem(with: nil)

        player = AVPlayer()
        configurePlayerInstance()
        updateOutputToneProfile(reloadIfNeeded: false)
        installPeriodicTimeObserver()
        loadedTrackID = nil
        loadedOfflineTrackID = nil

        audioSessionConfigured = false
        let audioSessionRestored = configureAudioSession()
        // The session came back, the headphones did not. Rebuilding on the
        // phone's own output is exactly the moment the reload below would
        // otherwise have played the track out loud.
        routeDisconnectPending =
            AudioAutoplayGatePolicy.retainsDisconnectPendingAfterReset(
                wasPending: disconnectWasPending,
                currentOutputPortTypes: AVAudioSession.sharedInstance()
                    .currentRoute.outputs.map(\.portType)
            )
        resumeAfterRouteTransfer = routeDisconnectPending && shouldAutoplay
        guard currentTrack != nil else { return }
        loadCurrent(
            autoplay: shouldAutoplay,
            startAt: position,
            automatic: true
        )
        if !audioSessionRestored {
            errorMessage = L10n.text(
                "Не удалось восстановить аудиовыход."
            )
        }
    }

    private func reloadCurrentItemForAudioProcessing() {
        guard currentTrack != nil else { return }
        let shouldResume = isPlaying
        let position = elapsedTime
        loadCurrent(
            autoplay: shouldResume,
            startAt: position,
            automatic: true
        )
    }

    private func updateOutputToneProfile(reloadIfNeeded: Bool) {
        let ports = AVAudioSession.sharedInstance()
            .currentRoute.outputs.map(\.portType)
        let profile = PlaybackOutputToneProfile.resolve(
            outputPortTypes: ports
        )
        let requiredTap = equalizer.requiresAudioTap
        equalizer.setOutputProfile(profile)
        let requiresAudioTap = equalizer.requiresAudioTap
        player.allowsExternalPlayback = AudioProcessingRoutePolicy
            .allowsExternalPlayback(requiresAudioTap: requiresAudioTap)
        guard reloadIfNeeded,
              requiredTap != requiresAudioTap,
              let item = player.currentItem else {
            return
        }
        // A tone-profile change (e.g. connecting to CarKit) can flip
        // whether a tap is required. Re-point the audio mix on the item
        // that is already playing instead of replacing it outright: a
        // full replaceCurrentItem forces a rebuffer, which is exactly the
        // multi-second silence-of-effects window users notice on route
        // changes. HLS sources never support a tap either way (the mix
        // stays nil regardless of what flipped), so there is nothing to
        // reattach for them.
        guard let url = (item.asset as? AVURLAsset)?.url,
              AudioProcessingAttachPolicy.supportsAudioTap(
                url: url,
                isOffline: loadedOfflineTrackID == currentTrack?.id
              ) else {
            return
        }
        if requiresAudioTap {
            attachAudioProcessing(to: item)
        } else {
            item.audioMix = nil
        }
    }

    private func handleOutputVolume(
        _ volume: Float,
        allowsAutomaticResume: Bool = true
    ) {
        let outputPortTypes = AVAudioSession.sharedInstance()
            .currentRoute.outputs.map(\.portType)
        if AudioRoutePolicy.shouldPause(
            volume: volume,
            enabled: pauseAtMinimumVolume,
            isPlaying: isPlaying,
            outputPortTypes: outputPortTypes
        ) {
            pausedForMinimumVolume = true
            minimumVolumeResumeSuppressed = false
            pausePreservingIntent()
            return
        }
        guard AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
            volume: volume,
            enabled: pauseAtMinimumVolume,
            pausedForMinimumVolume: pausedForMinimumVolume,
            playbackIntended: playbackIntended,
            hasCurrentTrack: currentTrack != nil,
            isPlaying: isPlaying,
            outputPortTypes: outputPortTypes,
            isAudioInterrupted: isAudioInterrupted,
            allowsAutomaticResume: allowsAutomaticResume
                && !minimumVolumeResumeSuppressed
                // Turning the volume back up is not the headphones coming
                // back, and this is a resume the app makes on its own.
                && allowsAutomaticPlayback
        ) else { return }
        resume(
            preservingMinimumVolumePause: true,
            preservingAppVolumePause: false
        )
    }

    private func advanceAfterCompletion() {
        // The queue does not walk on through the device speaker after the
        // headphones went away — the intent is kept so the next route the
        // user connects picks the queue back up.
        guard allowsAutomaticPlayback else {
            resumeAfterRouteTransfer = playbackIntended
            pausePreservingIntent()
            return
        }
        if sleepTimerMode == .endOfTrack {
            cancelSleepTimer()
            pause()
            return
        }
        if shouldStopForEndOfQueueTimer {
            cancelSleepTimer()
            pause()
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    private func publishPlaybackState(force: Bool = false) {
        let second = Int(elapsedTime.rounded(.down))
        guard NowPlayingDriftPolicy.shouldPublish(
            elapsedSeconds: second,
            lastPublishedSecond: lastNowPlayingSecond,
            force: force
        ) else {
            return
        }
        lastNowPlayingSecond = second
        nowPlaying.updatePlayback(
            elapsedTime: elapsedTime,
            rate: isPlaying ? 1 : 0
        )
    }

    private func publishNowPlayingQueue() {
        nowPlaying.updateQueue(
            count: queue.count,
            index: currentIndex ?? 0
        )
    }

    private func handleItemFailure(_ error: Error?) {
        publishPlaybackState(force: true)
        if let track = currentTrack,
           loadedOfflineTrackID == track.id {
            loadedOfflineTrackID = nil
            offlineInvalidationHandler?(track)
            didAttemptStreamRefresh = false
            if track.streamURL != nil {
                loadCurrent(
                    autoplay: true,
                    startAt: elapsedTime,
                    automatic: true
                )
            } else if streamRefreshProvider != nil {
                refreshCurrentStream(autoplay: true, automatic: true)
            }
            return
        }
        // After CarKit media-services reset, prefer one same-track reload
        // over cascading through the queue with skip-on-error.
        if MediaServicesResetPolicy.shouldSuppressAdvance(
            now: Date(),
            suppressUntil: suppressAdvanceUntil
        ),
           currentTrack != nil {
            suppressAdvanceUntil = nil
            didAttemptStreamRefresh = false
            streamRecoveryAttempts = 0
            loadCurrent(
                autoplay: playbackIntended,
                startAt: elapsedTime,
                automatic: true
            )
            return
        }

        streamRecoveryAttempts += 1
        if StreamFailureRetryPolicy.shouldRetrySameTrack(
            attempts: streamRecoveryAttempts,
            error: error,
            condition: currentNetworkCondition
        ) {
            scheduleSameTrackRecovery(autoplay: true, automatic: true)
            return
        }

        if StreamFailureRetryPolicy.shouldAdvance(
            attempts: streamRecoveryAttempts,
            error: error,
            advanceOnPlaybackError: advanceOnPlaybackError
        ),
           advancePastFailedTrackIfPossible() {
            return
        }

        let urlError = error as? URLError
        errorMessage = L10n.text(
            StreamFailureRetryPolicy.isConnectivityFailure(error)
                ? "Слабое соединение. Плеер продолжает пробовать этот трек."
                : urlError?.code == .cancelled
                    ? "Аудиопоток был прерван. Повторите воспроизведение."
                    : "Не удалось воспроизвести этот трек. "
                        + "Проверьте подключение и попробуйте ещё раз."
        )
        isBuffering = StreamFailureRetryPolicy.isConnectivityFailure(error)
        Haptics.error()
    }

    private func scheduleSameTrackRecovery(
        autoplay: Bool,
        automatic: Bool = false
    ) {
        cancelStreamRecovery()
        isPlaying = false
        isBuffering = true
        errorMessage = nil
        let position = elapsedTime
        let delay = StreamFailureRetryPolicy.retryDelay(
            forAttempt: streamRecoveryAttempts,
            condition: currentNetworkCondition
        )
        let generation = playbackGeneration
        let trackID = currentTrack?.id
        streamRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  generation == self.playbackGeneration,
                  self.currentTrack?.id == trackID else {
                return
            }
            self.didAttemptStreamRefresh = false
            if self.streamRefreshProvider != nil {
                self.refreshCurrentStream(
                    autoplay: autoplay,
                    automatic: automatic
                )
            } else {
                self.loadCurrent(
                    autoplay: autoplay,
                    startAt: position,
                    automatic: automatic
                )
            }
        }
    }

    private func recoverFromExtendedStall() {
        guard playbackIntended, currentTrack != nil else {
            extendedStallGuardBlockedSince = nil
            return
        }
        if streamRecoveryTask != nil || streamRefreshTask != nil {
            // A task is still on record as in flight. Most of the time that
            // is a legitimate same-track retry still waiting out its delay
            // — but a task whose own guard clause returned early (a
            // generation or track-ID mismatch) never reaches the code that
            // clears the stored reference, so this guard could otherwise
            // stay shut forever on a task that has already finished doing
            // nothing. Give it one stall cycle's worth of benefit of the
            // doubt before treating it as orphaned.
            if StallRecoveryGuardPolicy.isOrphaned(
                blockedSince: extendedStallGuardBlockedSince,
                now: Date()
            ) {
                cancelStreamRecovery()
                cancelStreamRefresh()
                extendedStallGuardBlockedSince = nil
            } else {
                if extendedStallGuardBlockedSince == nil {
                    extendedStallGuardBlockedSince = Date()
                }
                return
            }
        } else {
            extendedStallGuardBlockedSince = nil
        }
        streamRecoveryAttempts += 1
        guard StreamFailureRetryPolicy.shouldRetrySameTrack(
            attempts: streamRecoveryAttempts,
            error: URLError(.timedOut)
        ) else {
            return
        }
        scheduleSameTrackRecovery(autoplay: true, automatic: true)
    }

    @discardableResult
    private func advancePastFailedTrackIfPossible() -> Bool {
        guard advanceOnPlaybackError,
              allowsAutomaticPlayback,
              let currentIndex,
              !queue.isEmpty else {
            return false
        }
        if MediaServicesResetPolicy.shouldSuppressAdvance(
            now: Date(),
            suppressUntil: suppressAdvanceUntil
        ) {
            return false
        }

        if currentIndex + 1 < queue.count {
            cancelContinuation()
            cancelMixRadioRefill()
            cancelStreamRefresh()
            cancelStreamRecovery()
            requiresStreamRefresh = false
            didAttemptStreamRefresh = false
            streamRecoveryAttempts = 0
            stallStartedAt = nil
            self.currentIndex = currentIndex + 1
            prunePinnedPlayNextIDs()
            errorMessage = nil
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrentAndPlay()
            return true
        }

        if activeContinuationProvider != nil {
            errorMessage = nil
            startContinuationIfNeeded()
            return true
        }

        guard repeatMode == .all, queue.count > 1 else {
            return false
        }
        cancelContinuation()
        cancelStreamRefresh()
        cancelStreamRecovery()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        streamRecoveryAttempts = 0
        stallStartedAt = nil
        self.currentIndex = 0
        errorMessage = nil
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
        return true
    }

    private func refreshCurrentStream(
        autoplay: Bool,
        automatic: Bool = false
    ) {
        guard streamRefreshTask == nil,
              let provider = streamRefreshProvider,
              let index = currentIndex,
              queue.indices.contains(index) else {
            return
        }
        let track = queue[index]
        let position = elapsedTime
        didAttemptStreamRefresh = true
        isBuffering = true
        streamRefreshGeneration += 1
        let generation = streamRefreshGeneration
        streamRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await provider(track)
                guard !Task.isCancelled,
                      generation == self.streamRefreshGeneration,
                      self.currentIndex == index,
                      self.currentTrack?.id == track.id else {
                    return
                }
                self.queue[index] = refreshed
                self.restoredTrackIDs.remove(track.id)
                self.requiresStreamRefresh = false
                self.streamRefreshTask = nil
                self.loadCurrent(
                    autoplay: autoplay,
                    startAt: position,
                    automatic: automatic
                )
            } catch is CancellationError {
                guard generation == self.streamRefreshGeneration else {
                    return
                }
                self.streamRefreshTask = nil
                self.isBuffering = false
            } catch {
                guard generation == self.streamRefreshGeneration else {
                    return
                }
                self.streamRefreshTask = nil
                // Re-enter the same-track retry budget instead of skipping
                // after the first flaky refresh.
                self.handleItemFailure(error)
            }
        }
    }

    private func cancelStreamRecovery() {
        streamRecoveryTask?.cancel()
        streamRecoveryTask = nil
    }

    private func cancelContinuation() {
        if advanceAfterContinuationPrefetch {
            isBuffering = false
        }
        continuationGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        continuationPrefetchTask?.cancel()
        continuationPrefetchTask = nil
        advanceAfterContinuationPrefetch = false
        // Stay latched in the current near-end window so jump/cancel does
        // not immediately start another prefetch for the same queue tip.
        continuationPrefetchInThreshold = ContinuationPrefetchPolicy
            .shouldPrefetch(
                currentIndex: currentIndex,
                queueCount: queue.count,
                libraryQueue: LibraryQueuePolicy.isLibraryQueue(queueSource)
            )
    }

    private func cancelMixRadioRefill() {
        mixRadioRefillGeneration += 1
        mixRadioRefillTask?.cancel()
        mixRadioRefillTask = nil
    }

    private func prunePinnedPlayNextIDs() {
        let liveIDs = Set(queue.map(\.id))
        pinnedPlayNextIDs = pinnedPlayNextIDs.intersection(liveIDs)
        if let currentIndex, queue.indices.contains(currentIndex) {
            let played = Set(queue.prefix(currentIndex + 1).map(\.id))
            pinnedPlayNextIDs.subtract(played)
        }
    }

    private func cancelStreamRefresh() {
        streamRefreshGeneration += 1
        streamRefreshTask?.cancel()
        streamRefreshTask = nil
        cancelStreamRecovery()
    }

    private func upcomingCountForCapacity() -> Int {
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return queue.count
        }
        return max(queue.count - currentIndex - 1, 0)
    }

    private func cappedUniqueContinuationAdditions(
        from proposed: [Track]
    ) -> [Track] {
        let additions = PlaybackQueueBuilder.uniqueAdditions(
            existing: queue,
            candidates: proposed
        )
        guard !additions.isEmpty else { return [] }
        return Array(
            additions.prefix(
                LibraryQueuePolicy.appendableCount(
                    upcomingCount: upcomingCountForCapacity(),
                    source: queueSource
                )
            )
        )
    }

    private func startContinuationIfNeeded() {
        guard continuationTask == nil else { return }
        continuationGeneration += 1
        let generation = continuationGeneration
        let sourceIndex = currentIndex
        continuationTask = Task { [weak self] in
            guard let self else { return }
            await self.continueQueueIfPossible(
                generation: generation,
                sourceIndex: sourceIndex
            )
            guard generation == self.continuationGeneration else {
                return
            }
            self.continuationTask = nil
        }
    }

    private func startContinuationPrefetch() {
        guard continuationPrefetchTask == nil,
              let provider = activeContinuationPrefetchProvider
                ?? activeContinuationProvider else {
            return
        }
        let generation = continuationGeneration
        let sourceIndex = currentIndex
        continuationPrefetchTask = Task { [weak self] in
            guard let self else { return }
            var additions: [Track] = []
            do {
                for attempt in 0..<3 {
                    let proposed = try await self.continuationTracks(
                        from: provider
                    )
                    guard !Task.isCancelled,
                          generation == self.continuationGeneration,
                          self.currentIndex == sourceIndex else {
                        return
                    }
                    additions = self.cappedUniqueContinuationAdditions(
                        from: proposed
                    )
                    if !additions.isEmpty { break }
                    if attempt < 2 {
                        try await Task.sleep(for: .milliseconds(180))
                    }
                }
            } catch {
                additions = []
            }
            guard !Task.isCancelled,
                  generation == self.continuationGeneration,
                  self.currentIndex == sourceIndex else {
                return
            }
            self.continuationPrefetchTask = nil
            let shouldAdvance = ContinuationAdvancePolicy.shouldAdvance(
                requested: self.advanceAfterContinuationPrefetch,
                playbackIntended: self.playbackIntended
            )
            self.advanceAfterContinuationPrefetch = false
            if !shouldAdvance {
                self.isBuffering = false
            }
            if !additions.isEmpty {
                self.queue.append(contentsOf: additions)
                self.sourceOrderedQueue.append(contentsOf: additions)
                self.persistPlayback()
                self.publishNowPlayingQueue()
                self.scheduleNeighborPreloads()
                if shouldAdvance,
                   let sourceIndex,
                   self.queue.indices.contains(sourceIndex + 1) {
                    self.currentIndex = sourceIndex + 1
                    self.resetProgressForTrackTransition()
                    self.persistPlayback()
                    self.loadCurrentAndPlay()
                }
            } else if shouldAdvance {
                self.startContinuationIfNeeded()
            }
        }
    }

    /// Prefetch while the upcoming window is short. A successful tiny page may
    /// still leave us under the threshold, so `scheduleNeighborPreloads` is
    /// allowed to chain another request after the current one completes.
    private func maybeStartContinuationPrefetch() {
        guard activeContinuationProvider != nil,
              continuationPrefetchTask == nil,
              continuationTask == nil else {
            return
        }
        let should = ContinuationPrefetchPolicy.shouldPrefetch(
            currentIndex: currentIndex,
            queueCount: queue.count,
            libraryQueue: LibraryQueuePolicy.isLibraryQueue(queueSource)
        )
        continuationPrefetchInThreshold = should
        guard should else { return }
        startContinuationPrefetch()
    }

    /// Append unique tracks to the active queue (background mix fill, or the
    /// next Медиатека page).
    ///
    /// Capacity comes from `LibraryQueuePolicy`, which hands a library queue
    /// a far larger ceiling than a mix: a library is a finite list the user
    /// owns, and the mix cap refused every page past the first, so a
    /// 833-track Медиатека played as «Трек 1 из 100».
    func appendToQueue(_ tracks: [Track]) {
        let filtered = mixTrackFilter?(tracks) ?? tracks
        let additions = PlaybackQueueBuilder.uniqueAdditions(
            existing: queue,
            candidates: filtered
        )
        guard !additions.isEmpty else { return }
        let capped = Array(
            additions.prefix(
                LibraryQueuePolicy.appendableCount(
                    upcomingCount: upcomingCountForCapacity(),
                    source: queueSource
                )
            )
        )
        guard !capped.isEmpty else { return }
        queue.append(contentsOf: capped)
        // Continuation fills arrive in source order too, so record them:
        // turning shuffle off must not strand a refilled tail at the back.
        sourceOrderedQueue.append(contentsOf: capped)
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
        // Do not call rerankUpcomingMix here. MixQueueRanker shuffles with
        // SystemRandomNumberGenerator — re-ranking on every background fill
        // made the upcoming queue jump around mid-listen.
    }

    /// Replace only the unplayed suffix — used when radio mode pulls a
    /// server-seeded recommendation page (`target_audio`).
    func replaceUpcoming(with tracks: [Track]) {
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        let head = Array(queue.prefix(currentIndex + 1))
        let existingUpcoming = Array(queue.suffix(from: currentIndex + 1))
        let filtered = mixTrackFilter?(tracks) ?? tracks
        let next = MixRadioUpcomingMergePolicy.merge(
            head: head,
            existingUpcoming: existingUpcoming,
            replacement: filtered,
            pinnedIDs: pinnedPlayNextIDs,
            limit: LibraryQueuePolicy.upcomingLimit(for: queueSource)
        )
        guard next.map(\.id) != queue.map(\.id) else { return }
        queue = next
        prunePinnedPlayNextIDs()
        invalidatePreloadedPlayback()
        persistPlayback()
        publishNowPlayingQueue()
        scheduleNeighborPreloads()
    }

    /// Drop the current track (dislike) and advance. Removes other copies of
    /// the same id from the remaining queue.
    func skipAndDropCurrent() {
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        let droppedID = queue[currentIndex].id
        var nextQueue = queue
        nextQueue.remove(at: currentIndex)
        nextQueue.removeAll { $0.id == droppedID }
        cancelContinuation()
        cancelMixRadioRefill()
        cancelStreamRefresh()
        requiresStreamRefresh = false
        didAttemptStreamRefresh = false
        pinnedPlayNextIDs.remove(droppedID)
        guard !nextQueue.isEmpty else {
            queue = []
            self.currentIndex = nil
            pause()
            persistPlayback()
            publishNowPlayingQueue()
            return
        }
        let nextIndex = min(currentIndex, nextQueue.count - 1)
        queue = nextQueue
        self.currentIndex = nextIndex
        prunePinnedPlayNextIDs()
        resetProgressForTrackTransition()
        persistPlayback()
        loadCurrentAndPlay()
        maybeStartContinuationPrefetch()
    }

    /// Mix radio: reorder upcoming tracks locally, then optionally refill
    /// from VK recommendations when the mode asks for a new candidate pool.
    ///
    /// Pass `refillFromServer: false` when only a local reorder is needed.
    /// Background `appendToQueue` must never call this — random reranks
    /// made the upcoming list jump mid-listen.
    func rerankUpcomingMix(
        mode: MixRadioMode,
        seed: Track? = nil,
        historyArtists: Set<String> = [],
        refillFromServer: Bool = true
    ) {
        mixRadioMode = mode
        guard let currentIndex,
              queue.indices.contains(currentIndex) else {
            return
        }
        let seedTrack = seed ?? queue[currentIndex]
        let reranked = MixQueueRanker.rerank(
            queue: queue,
            currentIndex: currentIndex,
            seed: seedTrack,
            mode: mode,
            historyArtists: historyArtists
        )
        if reranked.map(\.id) != queue.map(\.id) {
            queue = reranked
            invalidatePreloadedPlayback()
            persistPlayback()
            publishNowPlayingQueue()
            scheduleNeighborPreloads()
        }
        guard refillFromServer else { return }
        if MixRadioRefillPolicy.shouldRefillFromServer(
            triggeredByAppend: false,
            mode: mode
        ) {
            startMixRadioRefill(seed: seedTrack, mode: mode)
        } else {
            cancelMixRadioRefill()
        }
    }

    private func startMixRadioRefill(seed: Track, mode: MixRadioMode) {
        guard let provider = mixRadioRefillProvider else { return }
        cancelMixRadioRefill()
        let generation = mixRadioRefillGeneration
        let seedID = seed.id
        mixRadioRefillTask = Task { [weak self] in
            do {
                let remote = try await provider(seed, mode)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let isMixQueue: Bool = {
                        if case .mix = self.queueSource { return true }
                        return false
                    }()
                    guard MixRadioRefillPolicy.shouldApplyRefill(
                        taskGeneration: generation,
                        currentGeneration: self.mixRadioRefillGeneration,
                        expectedMode: mode,
                        currentMode: self.mixRadioMode,
                        expectedSeedID: seedID,
                        currentTrackID: self.currentTrack?.id,
                        isMixQueue: isMixQueue
                    ) else {
                        return
                    }
                    let filtered = self.mixTrackFilter?(remote) ?? remote
                    let ranked = MixQueueRanker.rerank(
                        queue: [seed] + filtered,
                        currentIndex: 0,
                        seed: seed,
                        mode: mode,
                        historyArtists: Set(
                            self.historyStore.entries.prefix(40)
                                .map(\.track.artist)
                        )
                    )
                    self.replaceUpcoming(with: Array(ranked.dropFirst()))
                }
            } catch {
                // Local ranking already applied.
            }
        }
    }

    /// Resume a pinned mix snapshot without re-fetching the whole stream.
    func resumePinned(
        _ snapshot: PinnedMixSnapshot,
        continuation: (() async throws -> [Track])? = nil
    ) {
        guard !snapshot.tracks.isEmpty else { return }
        let index = min(
            max(snapshot.currentIndex, 0),
            snapshot.tracks.count - 1
        )
        let track = snapshot.tracks[index]
        play(
            track,
            in: snapshot.tracks,
            continuation: continuation,
            source: .mix(title: snapshot.mixTitle)
        )
        if snapshot.elapsed > 1 {
            seek(to: snapshot.elapsed)
        }
    }

    private func continueQueueIfPossible(
        generation: Int,
        sourceIndex: Int?
    ) async {
        guard let continuationProvider = activeContinuationProvider else {
            pause()
            return
        }
        do {
            var additions: [Track] = []
            for attempt in 0..<3 {
                let proposed = try await continuationTracks(
                    from: continuationProvider
                )
                guard !Task.isCancelled,
                      generation == continuationGeneration,
                      currentIndex == sourceIndex else {
                    return
                }
                additions = cappedUniqueContinuationAdditions(from: proposed)
                if !additions.isEmpty {
                    break
                }
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(180))
                }
            }
            guard !additions.isEmpty else {
                isBuffering = false
                pause()
                return
            }
            queue.append(contentsOf: additions)
            sourceOrderedQueue.append(contentsOf: additions)
            if let currentIndex {
                self.currentIndex = currentIndex + 1
            }
            resetProgressForTrackTransition()
            persistPlayback()
            loadCurrentAndPlay()
        } catch is CancellationError {
            return
        } catch let error as APIError
            where error == .unauthorized || error.isConnectivityFailure {
            isBuffering = false
            pause()
            return
        } catch {
            isBuffering = false
            pause()
            return
        }
    }

    private func continuationTracks(
        from provider: () async throws -> [Track]
    ) async throws -> [Track] {
        do {
            return try await provider()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            // Authorization recovery belongs to AppEnvironment. Repeating it
            // here would start a second cookie exchange after the centralized
            // recovery has already been exhausted.
            throw error
        } catch {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            return try await provider()
        }
    }

    private func updateElapsedTime(
        _ value: TimeInterval,
        forceProgressPublish: Bool = false
    ) {
        let sanitized = max(value, 0)
        elapsedTime = sanitized
        if forceProgressPublish {
            progress.reset(to: sanitized)
        } else {
            progress.update(sanitized)
        }
    }

    private func persistPlayback(forceFullSnapshot: Bool = false) {
        guard !queue.isEmpty, let currentIndex else { return }
        defaults.set(elapsedTime, forKey: PlaybackSnapshot.elapsedKey)
        let signature = queue.map(\.id).joined(separator: "|")
            + "#\(currentIndex)"
        guard forceFullSnapshot || signature != lastPersistedQueueSignature
        else {
            return
        }
        let snapshot = PlaybackSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            elapsedTime: elapsedTime
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: PlaybackSnapshot.key)
        lastPersistedQueueSignature = signature
    }

    private func resetProgressForTrackTransition() {
        loadedTrackID = nil
        loadedOfflineTrackID = nil
        updateElapsedTime(0, forceProgressPublish: true)
        duration = currentTrack?.duration ?? 0
        lastPersistedSecond = -1
        lastNowPlayingSecond = -1
        listenedTrackID = nil
        listenedPlaybackDuration = 0
        lastListeningElapsedTime = nil
    }

    private func sampleListeningProgress() {
        let sample = elapsedTime
        defer { lastListeningElapsedTime = sample }
        guard isPlaying,
              player.timeControlStatus == .playing,
              let previous = lastListeningElapsedTime else {
            return
        }
        let delta = sample - previous
        guard delta > 0, delta <= 1.5 else { return }
        listenedPlaybackDuration += delta
        markCurrentTrackListenedIfNeeded()
    }

    private func markCurrentTrackListenedIfNeeded() {
        guard let track = currentTrack,
              ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: listenedPlaybackDuration,
                duration: duration,
                alreadyMarked: listenedTrackID == track.id
              ) else {
            return
        }
        listenedTrackID = track.id
        historyStore.record(track)
        if loadedOfflineTrackID == track.id {
            offlinePlayedHandler?(track)
        }
    }

    private func restorePlayback() {
        guard let data = defaults.data(forKey: PlaybackSnapshot.key),
              let snapshot = try? JSONDecoder().decode(
                PlaybackSnapshot.self,
                from: data
              ),
              snapshot.queue.indices.contains(snapshot.currentIndex) else {
            return
        }
        queue = snapshot.queue
        sourceOrderedQueue = snapshot.queue
        restoredTrackIDs = Set(snapshot.queue.map(\.id))
        currentIndex = snapshot.currentIndex
        loadedTrackID = nil
        duration = currentTrack?.duration ?? 0
        let storedElapsed = defaults.object(
            forKey: PlaybackSnapshot.elapsedKey
        ) as? TimeInterval
        let restoredPosition = max(storedElapsed ?? snapshot.elapsedTime, 0)
        updateElapsedTime(
            duration > 0 ? min(restoredPosition, duration) : restoredPosition,
            forceProgressPublish: true
        )
        lastPersistedQueueSignature = snapshot.queue.map(\.id).joined(separator: "|")
            + "#\(snapshot.currentIndex)"
        requiresStreamRefresh = true
        if let track = currentTrack {
            nowPlaying.update(
                track: track,
                elapsedTime: elapsedTime,
                rate: 0,
                queueCount: queue.count,
                queueIndex: currentIndex ?? 0
            )
        }
    }
}

private struct PlaybackSnapshot: Codable {
    static let key = "player.playback.snapshot.v1"
    static let elapsedKey = "player.playback.elapsed.v1"

    let queue: [Track]
    let currentIndex: Int
    let elapsedTime: TimeInterval
}
