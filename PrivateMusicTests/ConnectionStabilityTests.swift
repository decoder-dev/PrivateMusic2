import AVFoundation
import XCTest
@testable import PrivateMusic

final class ConnectionStabilityTests: XCTestCase {
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

    func testInterruptionResumeRequiresSystemPermissionAndPlaybackIntent() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: false,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                options: []
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
