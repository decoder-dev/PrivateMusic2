import AVFoundation
import MediaPlayer

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

/// Configures `AVAudioSession` for music playback with graceful fallbacks.
///
/// `allowBluetoothA2DP` is rejected on some simulator / policy combinations
/// when paired with `longFormAudio`; fall back to the plain category so CI
/// and older runtimes still activate the session.
enum PlaybackAudioSessionPolicy {
    static func configure(
        _ session: AVAudioSession = .sharedInstance()
    ) -> Bool {
        let optionSets: [AVAudioSession.CategoryOptions] = [
            [.allowBluetoothA2DP],
            []
        ]
        for options in optionSets {
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio,
                    options: options
                )
                // Leave sample rate at the hardware / stream default (VK MP3 is
                // usually 44.1 kHz). Forcing 48 kHz resamples every buffer.
                if #available(iOS 17.0, *) {
                    try? session.setPrefersInterruptionOnRouteDisconnect(true)
                }
                return true
            } catch {
                continue
            }
        }
        return false
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
        return !StreamQualityPolicy.isHLSStream(url)
    }

    /// After media-services reset (typical on car attach), suppress auto-skip
    /// briefly so a transient item failure retries the same track instead of
    /// jumping through the queue with error toasts.
    static let postResetAdvanceSuppression: TimeInterval = 8
}
