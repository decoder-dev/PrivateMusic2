import XCTest
@testable import PrivateMusic

/// A device log showed the shape of the problem this policy exists for: a
/// token exchange at 10:21:08, then the very next track failing at
/// 10:21:09 with "Запрошенный URL не был обнаружен на этом сервере", and
/// 183 more queued behind it with URLs signed by the same dead session.
final class StreamCredentialPolicyTests: XCTestCase {
    func testAStaleURLIsRefreshedBeforePlayingRatherThanAfterFailing() {
        XCTAssertTrue(
            StreamCredentialPolicy.shouldRefreshBeforePlay(
                isStale: true,
                hasOfflineURL: false,
                hasRemoteURL: true,
                canRefresh: true
            )
        )
    }

    func testAURLFromTheLiveSessionIsPlayedAsItIs() {
        XCTAssertFalse(
            StreamCredentialPolicy.shouldRefreshBeforePlay(
                isStale: false,
                hasOfflineURL: false,
                hasRemoteURL: true,
                canRefresh: true
            )
        )
    }

    /// A downloaded file carries no credentials, so nothing about it can go
    /// stale. Blocking it on a network round trip would break offline
    /// playback at exactly the moment the network is worst.
    func testADownloadedTrackNeverWaitsOnTheNetwork() {
        XCTAssertFalse(
            StreamCredentialPolicy.shouldRefreshBeforePlay(
                isStale: true,
                hasOfflineURL: true,
                hasRemoteURL: true,
                canRefresh: true
            )
        )
    }

    /// With no way to fetch a new URL, holding playback back would replace
    /// a track that might still work with one that certainly does not.
    func testWithoutARefreshProviderPlaybackIsNotHeldBack() {
        XCTAssertFalse(
            StreamCredentialPolicy.shouldRefreshBeforePlay(
                isStale: true,
                hasOfflineURL: false,
                hasRemoteURL: true,
                canRefresh: false
            )
        )
    }

    /// A track with no remote URL at all is the missing-stream case, which
    /// `StreamURLLoadPolicy` already owns.
    func testATrackWithNoRemoteURLIsLeftToTheMissingStreamPath() {
        XCTAssertFalse(
            StreamCredentialPolicy.shouldRefreshBeforePlay(
                isStale: true,
                hasOfflineURL: false,
                hasRemoteURL: false,
                canRefresh: true
            )
        )
    }
}

/// The other half of the same log: four requests fired at 10:21:08 with a
/// token the app had just logged as `expired=true`, all four rejected, all
/// four repeated after the exchange. `withAuthorizedToken` asks these two
/// questions before spending the first round trip.
final class ProactiveSessionRefreshTests: XCTestCase {
    private func session(
        expiresIn seconds: TimeInterval,
        refreshable: Bool = true
    ) -> Session {
        Session(
            accessToken: "token",
            userAgent: "agent",
            userID: 1,
            expiresAt: Date().addingTimeInterval(seconds),
            refreshCookie: refreshable ? "cookie" : nil,
            webUserAgent: refreshable ? "web-agent" : nil
        )
    }

    func testAnExpiredRefreshableSessionIsRefreshedFirst() {
        let expired = session(expiresIn: -60)

        XCTAssertTrue(expired.shouldRefreshProactively)
        XCTAssertTrue(expired.canRefresh)
    }

    /// The leeway matters as much as the expiry: a token with seconds left
    /// would otherwise be spent on a request that outlives it.
    func testATokenAboutToExpireCountsAsExpired() {
        XCTAssertTrue(session(expiresIn: 30).shouldRefreshProactively)
        XCTAssertFalse(session(expiresIn: 3_600).shouldRefreshProactively)
    }

    /// Without refresh material there is nothing to exchange, so the old
    /// token still gets its turn rather than being discarded.
    func testAnExpiredSessionWithNothingToExchangeIsStillUsed() {
        let stranded = session(expiresIn: -60, refreshable: false)

        XCTAssertTrue(stranded.shouldRefreshProactively)
        XCTAssertFalse(stranded.canRefresh)
    }
}
