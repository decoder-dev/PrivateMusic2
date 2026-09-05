import AVFoundation
import MediaPlayer

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

/// Resume path for a phone call that has already released the session but
/// never asked to resume the way an ordinary interruption does.
///
/// iOS attaches `.shouldResume` to `.ended` when it judges the interruption
/// worth restarting on its own, and is documented to withhold that option
/// once the app has spent the call in the background — the exact report
/// this exists for: the call ends, the app is still backgrounded, and
/// nothing plays again until it is reopened by hand. `otherAudioWasPlaying`
/// is the same signal `AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause`
/// already uses to tell a call apart from Automatic Ear Detection, so
/// leaning on it here cannot resume through a deliberate headphone pause —
/// that branch has already returned by the time this one is reached.
enum PostCallResumePolicy {
    static func shouldResumeWithoutOption(
        wasPlayingBeforeInterruption: Bool,
        playbackIntended: Bool,
        otherAudioWasPlaying: Bool,
        routeDisconnectPending: Bool,
        beganAsRouteDisconnect: Bool
    ) -> Bool {
        wasPlayingBeforeInterruption
            && playbackIntended
            && otherAudioWasPlaying
            && !routeDisconnectPending
            && !beganAsRouteDisconnect
    }

    /// Safety net for an `.ended` that either arrived while the app was
    /// suspended (so nothing ran) or never arrived at all before the app
    /// was jettisoned mid-call. `RootView` forwards `scenePhase == .active`
    /// into this so playback picks back up once the app is frontmost
    /// again, with no dependency on the interruption notification firing.
    static func shouldResumeOnForeground(
        playbackIntended: Bool,
        isPlaying: Bool,
        isAudioInterrupted: Bool,
        hasPendingInterruptionResume: Bool,
        routeDisconnectPending: Bool
    ) -> Bool {
        playbackIntended
            && !isPlaying
            && !isAudioInterrupted
            && !hasPendingInterruptionResume
            && !routeDisconnectPending
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
