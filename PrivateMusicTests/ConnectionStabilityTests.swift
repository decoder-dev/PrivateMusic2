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

    func testKnownExpiringSessionRefreshesProactively() {
        let session = makeSession(
            expiresAt: Date().addingTimeInterval(30)
        )

        XCTAssertTrue(session.shouldRefreshProactively)
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
                isPlaying: true
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0.5,
                enabled: true,
                isPlaying: true
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0,
                enabled: false,
                isPlaying: true
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.shouldPause(
                volume: 0,
                enabled: true,
                isPlaying: false
            )
        )
    }

    func testBluetoothRoutePolicyRecognizesPlaybackPorts() {
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothA2DP))
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothHFP))
        XCTAssertTrue(AudioRoutePolicy.isBluetooth(.bluetoothLE))
        XCTAssertFalse(AudioRoutePolicy.isBluetooth(.builtInSpeaker))
        XCTAssertFalse(AudioRoutePolicy.isBluetooth(.airPlay))
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
