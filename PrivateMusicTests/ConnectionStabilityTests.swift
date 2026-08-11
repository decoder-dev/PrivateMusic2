import AVFoundation
import XCTest
@testable import PrivateMusic

final class ConnectionStabilityTests: XCTestCase {
    func testAudioProcessingKeepsAllOutputsOnLocalDecodePath() {
        XCTAssertFalse(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: true
            )
        )
        XCTAssertTrue(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: false
            )
        )
    }

    func testStreamFailureRetryKeepsConnectivityOnSameTrack() {
        XCTAssertTrue(
            StreamFailureRetryPolicy.isConnectivityFailure(
                APIError.timedOut
            )
        )
        XCTAssertTrue(
            StreamFailureRetryPolicy.isConnectivityFailure(
                URLError(.networkConnectionLost)
            )
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.isConnectivityFailure(
                APIError.invalidResponse
            )
        )
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: 1,
                error: APIError.timedOut
            )
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: 8,
                error: APIError.timedOut,
                advanceOnPlaybackError: true
            ),
            "Weak networks must not auto-skip the current track"
        )
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: StreamFailureRetryPolicy.maximumSameTrackAttempts + 1,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: true
            )
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: StreamFailureRetryPolicy.maximumSameTrackAttempts,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: true
            )
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: StreamFailureRetryPolicy.maximumSameTrackAttempts + 1,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: false
            )
        )
        XCTAssertEqual(
            StreamFailureRetryPolicy.preferredForwardBufferDuration,
            30,
            accuracy: 0.001
        )
    }

    func testPlaybackPreloadPolicyUsesShortForwardBuffer() {
        XCTAssertEqual(
            PlaybackPreloadPolicy.preferredForwardBufferDuration,
            10,
            accuracy: 0.001
        )
    }

    func testPreloadBufferPromotesToStreamingDurationOnceActive() {
        XCTAssertEqual(
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: false
            ),
            PlaybackPreloadPolicy.preferredForwardBufferDuration,
            accuracy: 0.001,
            "A track that only sits in the preload slot should keep its ~10s warm-up buffer"
        )
        XCTAssertEqual(
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: true
            ),
            StreamFailureRetryPolicy.preferredForwardBufferDuration,
            accuracy: 0.001,
            "Promoting a preloaded item to active playback must widen its buffer for stall resilience"
        )
    }

    func testAudioTapSupportedForProgressiveAndOfflineButNotHLS() {
        let progressive = URL(string: "https://example.com/audio.mp3")!
        let hls = URL(string: "https://example.com/index.m3u8")!
        let offline = URL(fileURLWithPath: "/tmp/track.m4a")
        XCTAssertTrue(
            AudioProcessingAttachPolicy.supportsAudioTap(
                url: progressive,
                isOffline: false
            )
        )
        XCTAssertFalse(
            AudioProcessingAttachPolicy.supportsAudioTap(
                url: hls,
                isOffline: false
            )
        )
        XCTAssertTrue(
            AudioProcessingAttachPolicy.supportsAudioTap(
                url: offline,
                isOffline: true
            ),
            "Offline packages are local files even when the remote source was HLS"
        )
    }

    func testMediaServicesResetSuppressesAdvanceWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            MediaServicesResetPolicy.shouldSuppressAdvance(
                now: now,
                suppressUntil: nil
            )
        )
        XCTAssertTrue(
            MediaServicesResetPolicy.shouldSuppressAdvance(
                now: now,
                suppressUntil: now.addingTimeInterval(8)
            )
        )
        XCTAssertFalse(
            MediaServicesResetPolicy.shouldSuppressAdvance(
                now: now.addingTimeInterval(9),
                suppressUntil: now.addingTimeInterval(8)
            )
        )
        XCTAssertEqual(
            AudioProcessingAttachPolicy.postResetAdvanceSuppression,
            8,
            accuracy: 0.001
        )
    }

    func testTransientPolicyRetriesOnlyConnectivityFailures() {
        XCTAssertEqual(RequestRetryPolicy.transient.maximumAttempts, 3)
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(.notConnectedToInternet)
        )
        XCTAssertTrue(RequestRetryPolicy.transient.shouldRetry(.timedOut))
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(.userAuthenticationRequired)
        )
    }

    func testMutationPolicyNeverRetries() {
        XCTAssertEqual(RequestRetryPolicy.never.maximumAttempts, 1)
        XCTAssertFalse(
            RequestRetryPolicy.never.shouldRetry(.networkConnectionLost)
        )
        XCTAssertFalse(
            RequestRetryPolicy.never.shouldRetry(statusCode: 429)
        )
        XCTAssertFalse(
            RequestRetryPolicy.never.shouldRetry(statusCode: 503)
        )
    }

    func testReadPolicyRetriesOnlyTransientHTTPFailures() {
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 429)
        )
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 408)
        )
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 503)
        )
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 401)
        )
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 404)
        )
    }

    func testHTTPAuthenticationStatusesAreClassifiedAsUnauthorized() {
        XCTAssertEqual(APIError.httpStatus(401), .unauthorized)
        guard case let .server(forbiddenCode, _) = APIError.httpStatus(403)
        else {
            return XCTFail("HTTP 403 is not proof of an expired token.")
        }
        XCTAssertEqual(forbiddenCode, 403)
        guard case let .server(code, _) = APIError.httpStatus(429) else {
            return XCTFail("HTTP 429 must remain a server error.")
        }
        XCTAssertEqual(code, 429)
    }

    func testSessionRefreshUsesDeterministicLeeway() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let session = makeSession(
            expiresAt: now.addingTimeInterval(119)
        )

        XCTAssertTrue(session.needsRefresh(at: now))
        XCTAssertFalse(
            session.needsRefresh(at: now, leeway: 60)
        )
        XCTAssertFalse(session.isExpired(at: now))
        XCTAssertTrue(
            session.isExpired(at: now.addingTimeInterval(120))
        )
    }

    func testSessionWithoutExpiryRemainsUsable() {
        let session = makeSession(expiresAt: nil)

        XCTAssertFalse(session.isExpired)
        XCTAssertFalse(session.needsRefresh)
        XCTAssertFalse(session.shouldRefreshProactively)
        XCTAssertTrue(session.canRefresh)
    }

    func testSessionWithoutExpiryIsValidatedBeforeCookieRefresh() {
        let session = makeSession(expiresAt: nil)

        XCTAssertFalse(session.shouldRefreshProactively)
        XCTAssertTrue(session.canRefresh)
    }

    func testWhitespaceOnlyRefreshCredentialsAreRejected() {
        let session = Session(
            accessToken: "0123456789abcdef",
            userAgent: nil,
            userID: 1,
            expiresAt: nil,
            refreshCookie: "  \n",
            webUserAgent: "\t"
        )

        XCTAssertFalse(session.canRefresh)
    }

    func testWebExchangeRejectsWhitespaceCredentialsWithoutNetworking() async {
        do {
            _ = try await VKWebAuthService().exchange(
                cookieHeader: " \n",
                webUserAgent: "\t"
            )
            XCTFail("Whitespace credentials must not start a request.")
        } catch VKWebAuthError.noSession {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKnownExpiringSessionRefreshesProactively() {
        let session = makeSession(
            expiresAt: Date().addingTimeInterval(30)
        )

        XCTAssertTrue(session.shouldRefreshProactively)
    }

    func testSessionMaintenanceRepeatsAndAvoidsExpiredTokenHotLoop() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(
            makeSession(expiresAt: nil).maintenanceDelay(at: now),
            900
        )
        XCTAssertEqual(
            makeSession(
                expiresAt: now.addingTimeInterval(600)
            ).maintenanceDelay(at: now),
            510
        )
        XCTAssertEqual(
            makeSession(
                expiresAt: now.addingTimeInterval(30)
            ).maintenanceDelay(at: now),
            900
        )
    }

    func testAddingResolvedUserIDPreservesRefreshCredentials() {
        let original = Session(
            accessToken: "0123456789abcdef",
            userAgent: "API Agent",
            userID: nil,
            expiresAt: Date(timeIntervalSince1970: 2_000_000),
            refreshCookie: "remixsid=test",
            webUserAgent: "Web Agent"
        )

        let updated = original.updatingUserID(42)

        XCTAssertEqual(updated.userID, 42)
        XCTAssertEqual(updated.accessToken, original.accessToken)
        XCTAssertEqual(updated.userAgent, original.userAgent)
        XCTAssertEqual(updated.expiresAt, original.expiresAt)
        XCTAssertEqual(updated.refreshCookie, original.refreshCookie)
        XCTAssertEqual(updated.webUserAgent, original.webUserAgent)
    }

    func testConnectivityErrorsAreClassifiedForBackgroundRecovery() {
        XCTAssertTrue(APIError.offline.isConnectivityFailure)
        XCTAssertTrue(APIError.timedOut.isConnectivityFailure)
        XCTAssertTrue(
            APIError.transport("Connection reset").isConnectivityFailure
        )
        XCTAssertFalse(APIError.unauthorized.isConnectivityFailure)
        XCTAssertFalse(
            APIError.server(code: 5, message: "Auth").isConnectivityFailure
        )
    }

    func testRecoveryPolicyDoesNotRetryRejectedCredentialsForever() {
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(APIError.unauthorized),
            .requiresLogin
        )
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(
                APIError.server(code: 5, message: "User authorization failed")
            ),
            .requiresLogin
        )
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(
                VKWebAuthError.rejected("Session expired")
            ),
            .requiresLogin
        )
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(APIError.offline),
            .retry
        )
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(
                VKWebAuthError.invalidResponse
            ),
            .retry
        )
        XCTAssertEqual(
            SessionRecoveryDisposition.classify(CancellationError()),
            .ignore
        )
    }

    func testRotatedVKCookieReplacesOldValueAndPreservesSession() {
        let result = VKWebAuthService.mergingCookieHeader(
            "remixlang=0; remixsid=old-value",
            responseHeaders: [
                "Set-Cookie":
                    "remixsid=new-value; Path=/; Secure; HttpOnly"
            ],
            url: URL(string: "https://login.vk.ru/")!
        )

        XCTAssertTrue(result.contains("remixlang=0"))
        XCTAssertTrue(result.contains("remixsid=new-value"))
        XCTAssertFalse(result.contains("old-value"))
    }

    func testMinimumVolumePolicyPausesOnlyActivePlayback() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldPause(
                volume: 0,
                enabled: true,
                isPlaying: true,
                outputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0.5,
                enabled: true,
                isPlaying: true,
                outputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0,
                enabled: false,
                isPlaying: true,
                outputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0,
                enabled: true,
                isPlaying: false,
                outputPortTypes: [.builtInSpeaker]
            )
        )
    }

    func testAppVolumeZeroPausesOnlyActivePlayback() {
        XCTAssertTrue(
            AppVolumePolicy.shouldPauseAtZero(volume: 0, isPlaying: true)
        )
        XCTAssertFalse(
            AppVolumePolicy.shouldPauseAtZero(volume: 0, isPlaying: false)
        )
        XCTAssertFalse(
            AppVolumePolicy.shouldPauseAtZero(volume: 0.2, isPlaying: true)
        )
    }

    func testAppVolumeResumesOnlyItsAutomaticPause() {
        XCTAssertTrue(
            AppVolumePolicy.shouldResumeAfterZeroPause(
                volume: 0.25,
                pausedForAppVolumeZero: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false
            )
        )
        XCTAssertFalse(
            AppVolumePolicy.shouldResumeAfterZeroPause(
                volume: 0.25,
                pausedForAppVolumeZero: false,
                playbackIntended: false,
                hasCurrentTrack: true,
                isPlaying: false
            )
        )
        XCTAssertFalse(
            AppVolumePolicy.shouldResumeAfterZeroPause(
                volume: 0.25,
                pausedForAppVolumeZero: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                isAudioInterrupted: true
            )
        )
    }

    func testRaisingVolumeResumesOnlyAutomaticMinimumVolumePause() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                volume: 0.25,
                enabled: true,
                pausedForMinimumVolume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                outputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                volume: 0,
                enabled: true,
                pausedForMinimumVolume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                outputPortTypes: [.builtInSpeaker]
            )
        )
    }

    func testRaisingVolumeDoesNotResumeManualPause() {
        for playbackIntended in [false, true] {
            XCTAssertFalse(
                AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                    volume: 0.5,
                    enabled: true,
                    pausedForMinimumVolume: playbackIntended == false,
                    playbackIntended: playbackIntended,
                    hasCurrentTrack: true,
                    isPlaying: false,
                    outputPortTypes: [.builtInSpeaker]
                )
            )
        }
    }

    func testDisablingMinimumVolumePauseResumesPendingTrack() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                volume: 0,
                enabled: false,
                pausedForMinimumVolume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                outputPortTypes: [.builtInSpeaker]
            )
        )
    }

    func testMinimumVolumePauseDoesNotResumeDuringInterruption() {
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                volume: 0.5,
                enabled: true,
                pausedForMinimumVolume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                outputPortTypes: [.builtInSpeaker],
                isAudioInterrupted: true
            )
        )
    }

    func testRoutePreferenceCanSuppressMinimumVolumeResume() {
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterMinimumVolumePause(
                volume: 0.5,
                enabled: true,
                pausedForMinimumVolume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                outputPortTypes: [.bluetoothA2DP],
                allowsAutomaticResume: false
            )
        )
    }

    func testMinimumVolumeNeverPausesExternalPlaybackRoutes() {
        for port in [
            AVAudioSession.Port.bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE,
            .airPlay,
            .carAudio,
            .HDMI,
            .usbAudio
        ] {
            XCTAssertFalse(
                AudioRoutePolicy.shouldPause(
                    volume: 0,
                    enabled: true,
                    isPlaying: true,
                    outputPortTypes: [port]
                ),
                "External route \(port.rawValue) must control its own volume"
            )
        }
    }

    func testRouteLossPausesOnlyWhenExternalOutputFallsBackToDevice() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: true,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: true,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.airPlay]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: false,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
    }

    /// Matches Apple's "Responding to audio route changes" guidance:
    /// pause on `.oldDeviceUnavailable` when headphones / earbuds leave.
    func testHeadphoneOrEarbudRemovalPausesPlayback() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: true,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: true,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: true,
                previousOutputPortTypes: [.bluetoothLE],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
    }

    // Unplugging raises an interruption and a route change, in either
    // order. When the interruption lands first it has already paused
    // playback and cleared the flags that said we were playing, so the
    // route change has to recognise the disconnect from the route alone —
    // otherwise nothing holds the session back from the speaker.
    func testRouteLossIsRecognizedWithoutALivePlaybackFlag() {
        XCTAssertTrue(
            AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInReceiver]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPauseAfterRouteLoss(
                wasPlaying: false,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "the playing test itself must keep its meaning"
        )
    }

    // Handing a wired unplug to already-connected AirPods is a transfer,
    // not a disconnect, and must not pause.
    func testMovingBetweenExternalRoutesIsNotARouteLoss() {
        XCTAssertFalse(
            AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: [.builtInSpeaker],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
    }

    // The resume scheduled at interruption end re-reads the route when it
    // fires: `.oldDeviceUnavailable` can still be in flight at that point,
    // and a resume that trusted the flags it was scheduled with restarted
    // playback on the speaker.
    func testDelayedInterruptionResumeRechecksTheRoute() {
        XCTAssertTrue(
            AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: false,
                playbackIntended: true,
                routeDisconnectPending: false,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: false,
                playbackIntended: true,
                routeDisconnectPending: false,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "the headphones are gone by the time the resume fires"
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: false,
                playbackIntended: true,
                routeDisconnectPending: true,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.allowsDelayedResume(
                isAudioInterrupted: false,
                playbackIntended: false,
                routeDisconnectPending: false,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    // «Наушники сняты — музыка играет дальше». Automatic Ear Detection
    // begins and ends an interruption in one breath while the AirPods stay
    // the current route, and the end even asks for a resume. Honouring it
    // is what plays the track on with the buds in the case.
    func testEarDetectionInterruptionEndIsADeliberatePause() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                interruptionDuration: 0.1,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
    }

    // iOS 17 names the reason, and that needs no timing at all: the buds
    // can sit out of the ear for as long as they like.
    func testANamedRouteDisconnectIsAPauseWhateverItsTiming() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                interruptionDuration: 240,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    // A call, Siri or another app holding the session still resumes: it
    // lasts far longer than the buds leaving an ear, and the route it ends
    // on is the same one it started with.
    func testALongInterruptionOnTheSameRouteStillResumes() {
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                interruptionDuration: 45,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                options: [.shouldResume]
            ),
            "the ordinary interruption path is untouched"
        )
    }

    // Nothing worn on the head, nothing to take off: a speaker or car
    // interruption is never read as the user pausing.
    func testOnlyAWornRouteCanEndAsADeliberatePause() {
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.builtInSpeaker],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.carAudio],
                currentOutputPortTypes: [.carAudio]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "a route that was lost belongs to the disconnect path"
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [],
                currentOutputPortTypes: []
            )
        )
    }

    // The fallback window has to be wider than the notification round-trip
    // and far narrower than any call.
    func testTheDeliberatePauseWindowStaysNarrow() {
        XCTAssertGreaterThanOrEqual(
            AudioInterruptionPolicy.deliberatePauseWindow,
            0.5
        )
        XCTAssertLessThanOrEqual(
            AudioInterruptionPolicy.deliberatePauseWindow,
            3
        )
    }

    // Nothing the app starts by itself may push audio through the speaker
    // while the headphones that were playing are gone: not a stream retry,
    // not a stall recovery, not the next track.
    func testAutomaticPlaybackWaitsWhileADisconnectIsPending() {
        XCTAssertFalse(
            AudioAutoplayGatePolicy.allowsAutomaticPlayback(
                routeDisconnectPending: true,
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioAutoplayGatePolicy.allowsAutomaticPlayback(
                routeDisconnectPending: true,
                currentOutputPortTypes: [.builtInReceiver]
            )
        )
        XCTAssertTrue(
            AudioAutoplayGatePolicy.allowsAutomaticPlayback(
                routeDisconnectPending: false,
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "playback the user asked for is not this policy's business"
        )
        XCTAssertTrue(
            AudioAutoplayGatePolicy.allowsAutomaticPlayback(
                routeDisconnectPending: true,
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "a new route took the playback over"
        )
    }

    // `.oldDeviceUnavailable` is read from a session that has not finished
    // switching, so `currentRoute` can still name the device that just went
    // away. Reading that as "nothing was lost" is the speaker leak.
    func testAStaleRouteStillCountsAsADisconnect() {
        XCTAssertTrue(
            AudioRoutePolicy.looksLikeStaleRouteLoss(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.looksLikeStaleRouteLoss(
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP, .builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.looksLikeStaleRouteLoss(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "a different external route is a transfer, not a stale read"
        )
        XCTAssertFalse(
            AudioRoutePolicy.looksLikeStaleRouteLoss(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "a settled loss is the ordinary disconnect path"
        )
    }

    // The wait exists so the route change can win the race; it is useless
    // if it is shorter than the gap between the two notifications.
    func testInterruptionResumeWaitsForTheRouteToSettle() {
        XCTAssertGreaterThanOrEqual(
            AudioInterruptionPolicy.routeSettleDelay,
            0.3
        )
        XCTAssertLessThanOrEqual(
            AudioInterruptionPolicy.routeSettleDelay,
            1
        )
    }

    func testRouteTransferResumeRequiresPendingPlaybackIntent() {
        XCTAssertTrue(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: true,
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: false,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: true,
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: true,
                playbackIntended: false,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: true,
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    func testBluetoothPreferenceAndExternalRouteGateTransferResume() {
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: false,
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: true,
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.shouldResumeAfterRouteTransfer(
                pendingResume: true,
                playbackIntended: true,
                hasCurrentTrack: true,
                isPlaying: false,
                resumeBluetoothEnabled: false,
                currentOutputPortTypes: [.carAudio]
            )
        )
    }

    func testInterruptionResumeRequiresSystemPermissionAndPlaybackIntent() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: false,
                routeDisconnectPending: false,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                options: []
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: true,
                options: [.shouldResume]
            ),
            "Headphone disconnect must not resume through the phone speaker"
        )
    }

    func testInterruptionEndDetectsRouteDisconnectRace() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: [.carAudio],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: [.builtInSpeaker],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsRouteDisconnect(
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.carAudio]
            )
        )
    }

    func testMediaServicesResetAutoplayKeepsListeningIntent() {
        XCTAssertTrue(
            MediaServicesResetPolicy.shouldAutoplayAfterReset(
                playbackIntended: true,
                wasActivelyPlaying: true
            )
        )
        XCTAssertFalse(
            MediaServicesResetPolicy.shouldAutoplayAfterReset(
                playbackIntended: true,
                wasActivelyPlaying: false
            )
        )
        XCTAssertFalse(
            MediaServicesResetPolicy.shouldAutoplayAfterReset(
                playbackIntended: false,
                wasActivelyPlaying: true
            )
        )
    }

    func testBluetoothRoutePolicyRecognizesPlaybackPorts() {
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothA2DP))
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothHFP))
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothLE))
        XCTAssertFalse(AudioRoutePolicy.isBluetooth(.builtInSpeaker))
        XCTAssertFalse(AudioRoutePolicy.isBluetooth(.airPlay))
        XCTAssertTrue(AudioRoutePolicy.isExternalPlayback(.airPlay))
        XCTAssertTrue(AudioRoutePolicy.isExternalPlayback(.carAudio))
        XCTAssertTrue(AudioRoutePolicy.isExternalPlayback(.bluetoothA2DP))
        XCTAssertFalse(
            AudioRoutePolicy.isExternalPlayback(.builtInSpeaker)
        )
    }

    private func makeSession(expiresAt: Date?) -> Session {
        Session(
            accessToken: "0123456789abcdef",
            userAgent: "PrivateMusicTests",
            userID: 1,
            expiresAt: expiresAt,
            refreshCookie: "remixsid=test",
            webUserAgent: "Mobile Safari"
        )
    }
}
