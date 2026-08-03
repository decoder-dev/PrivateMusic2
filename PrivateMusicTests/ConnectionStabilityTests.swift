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
