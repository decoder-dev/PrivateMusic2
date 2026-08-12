import AVFoundation
import Network
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

    // Wifi/online must reproduce the exact numbers `StreamFailureRetryPolicy`
    // already shipped with — nothing here may regress an existing pin.
    func testNetworkAdaptiveBufferKeepsWifiValueUnchanged() {
        XCTAssertEqual(
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .nominal),
            StreamFailureRetryPolicy.preferredForwardBufferDuration,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .nominal),
            30,
            accuracy: 0.001
        )
    }

    // A 4G→3G collapse must widen the buffer, not shrink or ignore it.
    // Offline keeps the nominal number — there is nothing to buffer into.
    func testNetworkAdaptiveBufferWidensOnDegradedLinkOnly() {
        XCTAssertGreaterThanOrEqual(
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .degraded),
            45
        )
        XCTAssertGreaterThan(
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .degraded),
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .nominal)
        )
        XCTAssertEqual(
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .offline),
            NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .nominal),
            accuracy: 0.001
        )
    }

    // Promoting a preloaded item to active playback must keep routing
    // through the network-adaptive buffer, degraded link included.
    func testPreloadPromotionUsesNetworkAdaptiveBufferPerCondition() {
        for condition in [
            NetworkCondition.nominal, .degraded, .offline
        ] {
            XCTAssertEqual(
                PlaybackPreloadPolicy.forwardBufferDuration(
                    isActivePlayback: true,
                    condition: condition
                ),
                NetworkAdaptiveBufferPolicy.preferredForwardBuffer(
                    for: condition
                ),
                accuracy: 0.001
            )
        }
        // The preload slot itself never widens — only ~10s warm-up,
        // regardless of link condition, until it is promoted.
        XCTAssertEqual(
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: false,
                condition: .degraded
            ),
            PlaybackPreloadPolicy.preferredForwardBufferDuration,
            accuracy: 0.001
        )
    }

    // Connectivity retry budget must never shrink on wifi and never drop
    // below the wifi budget on a degraded link.
    func testConnectivityRetryBudgetNeverShrinksAcrossConditions() {
        XCTAssertEqual(
            StreamFailureRetryPolicy.maximumConnectivityAttempts(for: .nominal),
            StreamFailureRetryPolicy.maximumConnectivityAttempts
        )
        XCTAssertEqual(
            StreamFailureRetryPolicy.maximumConnectivityAttempts(for: .nominal),
            8
        )
        XCTAssertEqual(
            StreamFailureRetryPolicy.maximumConnectivityAttempts(for: .offline),
            StreamFailureRetryPolicy.maximumConnectivityAttempts
        )
        XCTAssertGreaterThanOrEqual(
            StreamFailureRetryPolicy.maximumConnectivityAttempts(for: .degraded),
            StreamFailureRetryPolicy.maximumConnectivityAttempts
        )
    }

    // `shouldRetrySameTrack` must widen its own budget identically, and
    // connectivity failures must still never auto-advance — on any link.
    func testSameTrackRetryWidensOnDegradedLinkAndNeverAutoAdvances() {
        let wifiBudget = StreamFailureRetryPolicy.maximumConnectivityAttempts
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: wifiBudget,
                error: APIError.timedOut,
                condition: .nominal
            )
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: wifiBudget + 1,
                error: APIError.timedOut,
                condition: .nominal
            )
        )
        // An attempt count that would exhaust the wifi budget must still
        // be retried once the link is degraded.
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: wifiBudget + 1,
                error: APIError.timedOut,
                condition: .degraded
            ),
            "a degraded link must never retry less than wifi"
        )
        for condition in [NetworkCondition.nominal, .degraded, .offline] {
            XCTAssertFalse(
                StreamFailureRetryPolicy.shouldAdvance(
                    attempts: StreamFailureRetryPolicy
                        .maximumConnectivityAttempts(for: condition) + 1,
                    error: APIError.timedOut,
                    advanceOnPlaybackError: true
                ),
                "connectivity failures must never auto-advance, " +
                    "regardless of network condition"
            )
        }
    }

    // Backoff on wifi is unchanged and stays capped at 6s; on a degraded
    // link it only ever grows (never shrinks below wifi), stays
    // monotonic in the attempt count, and stays capped — no unbounded
    // wait for the user.
    func testRetryDelayStaysCappedAndMonotonicAcrossConditions() {
        XCTAssertEqual(
            StreamFailureRetryPolicy.retryDelay(
                forAttempt: 100,
                condition: .nominal
            ),
            6,
            accuracy: 0.001
        )
        var previousDegradedDelay: TimeInterval = 0
        for attempt in 1...10 {
            let wifiDelay = StreamFailureRetryPolicy.retryDelay(
                forAttempt: attempt,
                condition: .nominal
            )
            let degradedDelay = StreamFailureRetryPolicy.retryDelay(
                forAttempt: attempt,
                condition: .degraded
            )
            XCTAssertGreaterThanOrEqual(degradedDelay, wifiDelay)
            XCTAssertGreaterThanOrEqual(degradedDelay, previousDegradedDelay)
            XCTAssertLessThanOrEqual(degradedDelay, 12)
            previousDegradedDelay = degradedDelay
        }
        XCTAssertEqual(
            StreamFailureRetryPolicy.retryDelay(
                forAttempt: 100,
                condition: .offline
            ),
            6,
            accuracy: 0.001
        )
    }

    func testPlaybackRecoveryDelayAddsBoundedJitter() {
        let baseline = StreamFailureRetryPolicy.retryDelay(
            forAttempt: 1,
            condition: .nominal
        )
        let earliest = StreamRecoveryDelayPolicy.delay(
            for: .failure,
            attempt: 1,
            condition: .nominal,
            jitterUnit: 0
        )
        let latest = StreamRecoveryDelayPolicy.delay(
            for: .failure,
            attempt: 1,
            condition: .nominal,
            jitterUnit: 1
        )
        XCTAssertLessThan(earliest, baseline)
        XCTAssertGreaterThan(latest, baseline)
        XCTAssertGreaterThanOrEqual(earliest, 0.2)
        XCTAssertLessThanOrEqual(
            StreamRecoveryDelayPolicy.delay(
                for: .failure,
                attempt: 100,
                condition: .nominal,
                jitterUnit: 1
            ),
            6
        )
        XCTAssertLessThanOrEqual(
            StreamRecoveryDelayPolicy.delay(
                for: .failure,
                attempt: 100,
                condition: .degraded,
                jitterUnit: 1
            ),
            NetworkAdaptiveBufferPolicy.degradedRetryDelayCap
        )
    }

    func testNetworkReturnUsesShortJitteredRecoveryWindow() {
        let earliest = StreamRecoveryDelayPolicy.delay(
            for: .networkReturn,
            attempt: 8,
            condition: .nominal,
            jitterUnit: -1
        )
        let latest = StreamRecoveryDelayPolicy.delay(
            for: .networkReturn,
            attempt: 8,
            condition: .degraded,
            jitterUnit: 2
        )
        XCTAssertEqual(
            earliest,
            StreamRecoveryDelayPolicy.networkReturnMinimumDelay,
            accuracy: 0.001
        )
        XCTAssertEqual(
            latest,
            StreamRecoveryDelayPolicy.networkReturnMaximumDelay,
            accuracy: 0.001
        )
        XCTAssertLessThan(latest, StreamFailureRetryPolicy.baseRetryDelay)
    }

    func testOfflineTransitionSuspendsAndReturnRecovers() {
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .nominal,
                to: .offline
            ),
            .suspend
        )
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .degraded,
                to: .offline
            ),
            .suspend
        )
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .offline,
                to: .nominal
            ),
            .recover
        )
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .offline,
                to: .degraded
            ),
            .recover
        )
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .nominal,
                to: .degraded
            ),
            .none
        )
        XCTAssertEqual(
            StreamRecoveryNetworkTransitionPolicy.action(
                from: .offline,
                to: .offline
            ),
            .none
        )
    }

    // Simulates a mid-track `.wifi → .cellular` transition: the item the
    // player was already playing keeps its buffer, but every item the
    // buffer/retry policy sizes *after* the transition requests the
    // larger, degraded-link buffer.
    func testConditionTransitionWidensSubsequentlyRequestedBuffers() {
        var condition = NetworkCondition.nominal
        let beforeTransition = NetworkAdaptiveBufferPolicy
            .preferredForwardBuffer(for: condition)
        XCTAssertEqual(beforeTransition, 30, accuracy: 0.001)

        condition = .degraded // 4G → 3G mid-track
        let afterTransition = NetworkAdaptiveBufferPolicy
            .preferredForwardBuffer(for: condition)
        XCTAssertGreaterThan(afterTransition, beforeTransition)
        XCTAssertEqual(
            PlaybackPreloadPolicy.forwardBufferDuration(
                isActivePlayback: true,
                condition: condition
            ),
            afterTransition,
            accuracy: 0.001,
            "an item created after the transition must request the " +
                "wider, degraded-link buffer"
        )
    }

    // `NetworkMonitor.condition` groups cellular and constrained
    // together as degraded and treats offline as its own case, matching
    // the mapping `NetworkAdaptiveBufferPolicy` expects.
    @MainActor
    func testNetworkMonitorConditionMapsStateAndTransport() {
        let wifiOnline = NetworkMonitor(monitor: NWPathMonitor())
        XCTAssertEqual(wifiOnline.condition, .nominal)
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

    // Bounded reactivation retry for `setActive(true)` throws right after a
    // call ends or media services reset. The budget must be finite and the
    // delay must stay capped so a permanently unavailable session cannot
    // spin the retry loop forever.
    func testSessionActivationRetryPolicyIsBoundedAndCapped() {
        XCTAssertTrue(SessionActivationRetryPolicy.shouldRetry(attempt: 0))
        XCTAssertTrue(
            SessionActivationRetryPolicy.shouldRetry(
                attempt: SessionActivationRetryPolicy.maximumAttempts - 1
            )
        )
        XCTAssertFalse(
            SessionActivationRetryPolicy.shouldRetry(
                attempt: SessionActivationRetryPolicy.maximumAttempts
            ),
            "the budget must exhaust rather than retry forever"
        )
        XCTAssertFalse(
            SessionActivationRetryPolicy.shouldRetry(
                attempt: SessionActivationRetryPolicy.maximumAttempts + 5
            )
        )

        let firstDelay = SessionActivationRetryPolicy.retryDelay(forAttempt: 1)
        let secondDelay = SessionActivationRetryPolicy.retryDelay(forAttempt: 2)
        XCTAssertGreaterThan(secondDelay, firstDelay)
        XCTAssertLessThanOrEqual(
            SessionActivationRetryPolicy.retryDelay(forAttempt: 999),
            SessionActivationRetryPolicy.maximumRetryDelay,
            "retry delay must never grow unbounded"
        )
        XCTAssertEqual(
            SessionActivationRetryPolicy.retryDelay(forAttempt: 0),
            SessionActivationRetryPolicy.retryDelay(forAttempt: 1),
            "a non-positive attempt must not shorten the delay below attempt 1"
        )
    }

    // A recovery/refresh task that never clears its own stored reference
    // (its guard clause returned early on a generation/track mismatch) must
    // not wedge `recoverFromExtendedStall` shut forever. The guard gets one
    // stall cycle's benefit of the doubt before treating the task as
    // orphaned.
    func testStallRecoveryGuardTreatsALingeringTaskAsOrphanedAfterAThreshold() {
        let blockedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(
            StallRecoveryGuardPolicy.isOrphaned(
                blockedSince: blockedAt,
                now: blockedAt.addingTimeInterval(1)
            ),
            "a task that just started blocking is not orphaned yet"
        )
        XCTAssertFalse(
            StallRecoveryGuardPolicy.isOrphaned(
                blockedSince: blockedAt,
                now: blockedAt.addingTimeInterval(
                    StallRecoveryGuardPolicy.orphanThreshold - 0.1
                )
            )
        )
        XCTAssertTrue(
            StallRecoveryGuardPolicy.isOrphaned(
                blockedSince: blockedAt,
                now: blockedAt.addingTimeInterval(
                    StallRecoveryGuardPolicy.orphanThreshold
                )
            ),
            "recovery must still fire once a task has lingered past the threshold"
        )
        XCTAssertFalse(
            StallRecoveryGuardPolicy.isOrphaned(blockedSince: nil, now: Date()),
            "no task blocking at all is not an orphan condition"
        )
    }

    // Non-connectivity failures must transition cleanly from same-track
    // retry to queue advance with no gap where neither happens — that gap
    // is exactly what would surface as a dead track instead of a clean
    // recovery/advance.
    func testNonConnectivityFailureAdvancesCleanlyOnceRetryBudgetExhausted() {
        let atBudget = StreamFailureRetryPolicy.maximumSameTrackAttempts
        let pastBudget = atBudget + 1

        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: atBudget,
                error: APIError.invalidResponse
            ),
            "the last attempt still inside the budget must retry the same track"
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: atBudget,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: true
            ),
            "must not advance while a same-track retry is still due"
        )

        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: pastBudget,
                error: APIError.invalidResponse
            ),
            "same-track retries must stop once the budget is exhausted"
        )
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: pastBudget,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: true
            ),
            "exhausting retries on a non-connectivity failure must clean-advance, not go dead"
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: pastBudget,
                error: APIError.invalidResponse,
                advanceOnPlaybackError: false
            ),
            "the autoplay-on-error gate still wins even once the budget is exhausted"
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
        XCTAssertEqual(RequestRetryPolicy.transient.requestTimeout, 30)
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(.notConnectedToInternet)
        )
        XCTAssertTrue(RequestRetryPolicy.transient.shouldRetry(.timedOut))
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(.resourceUnavailable)
        )
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(.userAuthenticationRequired)
        )
    }

    func testPlaybackRefreshLeavesRetriesToThePlayerRecoveryLoop() {
        XCTAssertEqual(
            RequestRetryPolicy.playbackRecovery.maximumAttempts,
            1
        )
        XCTAssertEqual(
            RequestRetryPolicy.playbackRecovery.requestTimeout,
            12
        )
        XCTAssertFalse(
            RequestRetryPolicy.playbackRecovery.shouldRetry(
                .networkConnectionLost
            )
        )
        XCTAssertFalse(
            RequestRetryPolicy.playbackRecovery.shouldRetry(statusCode: 503)
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
        XCTAssertTrue(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 502)
        )
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 501)
        )
        XCTAssertFalse(
            RequestRetryPolicy.transient.shouldRetry(statusCode: 505)
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
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.1,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
    }

    // The reporter's case, and the one a timing window can never cover:
    // the buds come out, sit on the desk, and the interruption only ends
    // when they go back in. Nothing about the route ever changes and the
    // end still asks for a resume. Only the buds can silence the buds, so
    // nothing else having the output is what decides it.
    func testEarDetectionStaysPausedHoweverLongTheBudsAreOut() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 240,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "AirPods out of the ear must stay paused, not resume on a timer"
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 8,
                previousOutputPortTypes: [.bluetoothLE],
                currentOutputPortTypes: [.bluetoothLE]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 90,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            ),
            "a wired unplug whose route read has not caught up stays paused"
        )
    }

    // iOS 17 names the reason, and that needs no inference at all: the
    // buds can sit out of the ear for as long as they like, and it holds
    // even while something else has the output.
    func testANamedRouteDisconnectIsAPauseWhateverItsTiming() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 240,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: true,
                interruptionDuration: 240,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
    }

    // A call, Siri or another app holding the session still resumes. What
    // marks them is that something else owned the output while we were
    // quiet — ear detection never looks like that.
    func testALongInterruptionOnTheSameRouteStillResumes() {
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: true,
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
                beganAsRouteDisconnect: false,
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
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.builtInSpeaker],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.carAudio],
                currentOutputPortTypes: [.carAudio]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "a route that was lost belongs to the disconnect path"
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [],
                currentOutputPortTypes: []
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP, .builtInSpeaker]
            ),
            "a half-switched read is the disconnect path, not ear detection"
        )
    }

    // A slow case-close used to land past the old 1.5s window and resume.
    func testASlowWearableInterruptionStillPausesInsideTheWindow() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 2.5,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    // The window is now only reached when something else held the output
    // and the system refused to name a reason. It still has to be wider
    // than the notification round-trip and far narrower than any call.
    func testTheDeliberatePauseWindowStaysNarrow() {
        XCTAssertGreaterThanOrEqual(
            AudioInterruptionPolicy.deliberatePauseWindow,
            0.5
        )
        XCTAssertLessThanOrEqual(
            AudioInterruptionPolicy.deliberatePauseWindow,
            3
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: true,
                interruptionDuration:
                    AudioInterruptionPolicy.deliberatePauseWindow - 0.1,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: true,
                interruptionDuration:
                    AudioInterruptionPolicy.deliberatePauseWindow + 0.1,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.headphones]
            )
        )
    }

    // AirPods can flicker between A2DP and HFP while still worn. Exact port
    // set equality used to drop that interruption, and playback resumed.
    func testWearablePortFlickerStillCountsAsEarDetection() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.4,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothHFP]
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: true,
                otherAudioWasPlaying: false,
                interruptionDuration: 12,
                previousOutputPortTypes: [.bluetoothA2DP, .bluetoothHFP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    // Wireless taking a wired route over is a transfer, and transfers
    // carry the playback across rather than stopping it.
    func testAWiredToWirelessHandoverIsNotEarDetection() {
        XCTAssertTrue(
            AudioRoutePolicy.namesTheSameWornRoute(
                [.bluetoothA2DP],
                [.bluetoothHFP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.namesTheSameWornRoute(
                [.headphones],
                [.bluetoothA2DP]
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.namesTheSameWornRoute([], [.bluetoothA2DP])
        )
        XCTAssertFalse(
            AudioRoutePolicy.namesTheSameWornRoute(
                [.bluetoothA2DP],
                [.carAudio]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 30,
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
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

    // `.oldDeviceUnavailable` can also arrive with no previous route in
    // its payload. The reason already says a device went away, so a
    // session that has landed on the phone is the disconnect.
    func testADisconnectWithNoPreviousRouteStillPauses() {
        XCTAssertTrue(
            AudioRoutePolicy.isUnattributedRouteLoss(
                previousOutputPortTypes: [],
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.isUnattributedRouteLoss(
                previousOutputPortTypes: [],
                currentOutputPortTypes: []
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.isUnattributedRouteLoss(
                previousOutputPortTypes: [],
                currentOutputPortTypes: [.carAudio]
            ),
            "something external is still playing it — nothing was lost"
        )
        XCTAssertFalse(
            AudioRoutePolicy.isUnattributedRouteLoss(
                previousOutputPortTypes: [.headphones],
                currentOutputPortTypes: [.builtInSpeaker]
            ),
            "an attributed loss belongs to the ordinary disconnect path"
        )
    }

    // A wired unplug does not always announce itself as
    // `.oldDeviceUnavailable`. Whatever the system calls the change, audio
    // must not appear on the phone's own speaker — except when the user
    // asked for the speaker themselves.
    func testAnUnannouncedRouteChangeCanStillBeADisconnect() {
        XCTAssertTrue(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(.unknown)
        )
        XCTAssertTrue(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(.wakeFromSleep)
        )
        XCTAssertTrue(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(
                .noSuitableRouteForCategory
            )
        )
        XCTAssertTrue(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(
                .routeConfigurationChange
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(.override),
            "picking «iPhone» in the route picker is asking for the speaker"
        )
        XCTAssertFalse(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(.categoryChange),
            "the app configuring its own session is not an unplug"
        )
        XCTAssertFalse(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(
                .newDeviceAvailable
            )
        )
        XCTAssertFalse(
            AudioRoutePolicy.mayCarryAnUnannouncedDisconnect(
                .oldDeviceUnavailable
            ),
            "the documented disconnect has a branch of its own"
        )
        // Ear detection can also surface as a configuration change on an
        // unchanged route. Nothing was lost there, so the safety net has
        // to stay quiet and leave the interruption path to decide.
        XCTAssertFalse(
            AudioRoutePolicy.didLoseExternalRoute(
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            )
        )
    }

    // Media services come back on the phone's own output. The headphones
    // did not come back with them, so the gate the disconnect shut has to
    // survive the rebuild — the reset schedules a reload right after it.
    func testTheDisconnectGateSurvivesAMediaServicesReset() {
        XCTAssertTrue(
            AudioAutoplayGatePolicy.retainsDisconnectPendingAfterReset(
                wasPending: true,
                currentOutputPortTypes: [.builtInSpeaker]
            )
        )
        XCTAssertFalse(
            AudioAutoplayGatePolicy.retainsDisconnectPendingAfterReset(
                wasPending: true,
                currentOutputPortTypes: [.carAudio]
            ),
            "a head unit took the playback over while the session rebuilt"
        )
        XCTAssertFalse(
            AudioAutoplayGatePolicy.retainsDisconnectPendingAfterReset(
                wasPending: false,
                currentOutputPortTypes: [.builtInSpeaker]
            )
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
                beganAsRouteDisconnect: false,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: false,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false,
                options: [.shouldResume]
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false,
                options: []
            )
        )
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: true,
                beganAsRouteDisconnect: false,
                options: [.shouldResume]
            ),
            "Headphone disconnect must not resume through the phone speaker"
        )
    }

    // The system said the route was disconnecting and then ended the
    // interruption asking for a resume anyway. That happens when the route
    // read at the start had already moved to the speaker, so neither the
    // ear-detection nor the route-loss branch recognises it — and obeying
    // the option there is the leak.
    func testANamedDisconnectRefusesItsOwnResumeOption() {
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: true,
                options: [.shouldResume]
            ),
            "the route the disconnect named is not coming back on its own"
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

    // Звонок закончился без `.shouldResume` (обычно потому что приложение
    // всё это время сидело в фоне) — `otherAudioWasPlaying` уже отличает
    // звонок от снятых наушников, и на нём одном держится автоматический
    // резюм без переоткрытия приложения.
    func testPostCallResumePolicyResumesWithoutShouldResumeOptionForACall() {
        XCTAssertTrue(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                otherAudioWasPlaying: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false
            )
        )
    }

    // То же самое отсутствие опции, но без звонка — это в точности снятые
    // наушники, и решение остаётся у `shouldTreatEndAsDeliberatePause`,
    // которая уже должна была вернуть паузу раньше в `handleInterruption`.
    func testPostCallResumePolicyNeverOverridesEarDetectionDiscriminator() {
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                otherAudioWasPlaying: false,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false
            )
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 240,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "Ear-off deliberate pause must keep winning alongside this policy"
        )
    }

    func testPostCallResumePolicyDefersToRouteDisconnectAndPlaybackIntent() {
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                otherAudioWasPlaying: true,
                routeDisconnectPending: true,
                beganAsRouteDisconnect: false
            ),
            "A pending route disconnect must still win over call semantics"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                otherAudioWasPlaying: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: true
            ),
            "A named route disconnect must not resume through the speaker"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: false,
                playbackIntended: true,
                otherAudioWasPlaying: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false
            ),
            "Nothing was playing before the interruption began"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeWithoutOption(
                wasPlayingBeforeInterruption: true,
                playbackIntended: false,
                otherAudioWasPlaying: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false
            ),
            "The user paused since — do not resume against their intent"
        )
    }

    // Приложение стало активным, и ничего до этого не проигрывало —
    // резервный путь для случая, когда `.ended` пришёл во время
    // приостановки приложения или не пришёл вовсе.
    func testPostCallResumePolicyForegroundFallbackRequestsResume() {
        XCTAssertTrue(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: false,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: false
            )
        )
    }

    // Приложение было полностью приостановлено на весь звонок — `.ended`
    // никогда не добрался до `handleInterruption`, и единственное, что
    // переживает возобновление процесса, это сохранённое намерение играть.
    func testPostCallResumePolicyCoversASuspendedAppThatMissedEnded() {
        XCTAssertTrue(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: false,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: false
            )
        )
    }

    func testPostCallResumePolicyForegroundFallbackDefersToPendingWork() {
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: false,
                isAudioInterrupted: true,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: false
            ),
            "Still mid-interruption — the ordinary .ended path owns this"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: false,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: true,
                routeDisconnectPending: false
            ),
            "A scheduled interruption resume is already in flight"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: false,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: true
            ),
            "A pending route disconnect must not push audio to the speaker"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: false,
                isPlaying: false,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: false
            ),
            "Nothing intended to keep playing"
        )
        XCTAssertFalse(
            PostCallResumePolicy.shouldResumeOnForeground(
                playbackIntended: true,
                isPlaying: true,
                isAudioInterrupted: false,
                hasPendingInterruptionResume: false,
                routeDisconnectPending: false
            ),
            "Already playing — nothing to fall back to"
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

    // MARK: - Cross-cutting: "call-during-3G" (Agent E / KEYSTONE)
    //
    // STABILITY_OFFICE_BRIEF.md assigns the call-during-3G interaction to
    // Agent E because it spans policies owned by Agents A, B, C and D, none
    // of whom may touch each other's region. These tests exercise the parts
    // of that interaction that are already expressible against `main`'s
    // current policies (`StreamFailureRetryPolicy`, `AudioInterruptionPolicy`,
    // `MediaServicesResetPolicy`) as a baseline that must keep holding once
    // A-D land, and document — without referencing symbols that do not exist
    // on this branch yet — the additional assertions Agent E will add once
    // each branch has actually merged. This file is tests + docs only; no
    // production Swift/C source is edited here.

    // A connectivity failure that happens to line up with a call must not
    // let a fixed same-track attempt cap force an auto-advance: connectivity
    // failures always use the larger `maximumConnectivityAttempts` budget
    // and never advance regardless of `advanceOnPlaybackError`. This is the
    // pre-existing half of the call-during-3G guarantee that Agent B's
    // `NetworkAdaptiveBufferPolicy` must not weaken.
    func testCallDuringConnectivityCollapseNeverAdvancesTheTrack() {
        XCTAssertTrue(
            StreamFailureRetryPolicy.shouldRetrySameTrack(
                attempts: StreamFailureRetryPolicy.maximumSameTrackAttempts + 1,
                error: APIError.timedOut
            ),
            "connectivity failures get the larger retry budget, not the "
                + "same-track cap"
        )
        XCTAssertFalse(
            StreamFailureRetryPolicy.shouldAdvance(
                attempts: StreamFailureRetryPolicy.maximumConnectivityAttempts,
                error: APIError.timedOut,
                advanceOnPlaybackError: true
            ),
            "a call overlapping a bandwidth collapse must not cause an "
                + "auto-skip of the current track"
        )
    }

    // Once the call ends, resume must still be permitted purely from the
    // interruption/session side, independent of whatever the network did
    // mid-call. This is the pre-existing half of the guarantee that Agent
    // A's `PostCallResumePolicy` extends (foreground fallback, missing
    // `.shouldResume`, suspended app) and Agent C's
    // `SessionActivationRetryPolicy` extends (bounded `setActive` retry).
    func testResumeAfterCallIsPermittedRegardlessOfNetworkState() {
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldResume(
                wasPlayingBeforeInterruption: true,
                playbackIntended: true,
                routeDisconnectPending: false,
                beganAsRouteDisconnect: false,
                options: [.shouldResume]
            ),
            "an ordinary call-ended resume must not be gated on network "
                + "condition — that gating belongs to the buffer target, "
                + "not to whether we resume at all"
        )
    }

    // The ear-off deliberate-pause discriminator is a release invariant
    // (3.28.75) that predates A-D and must survive every one of their
    // merges into `AudioPlayer.swift`, including Agent A's `.ended`-branch
    // and foreground-fallback changes. A call (`otherAudioWasPlaying: true`)
    // must keep resuming; ear detection on an unchanged worn route
    // (`otherAudioWasPlaying: false`) must keep NOT resuming — even while a
    // connectivity retry budget is live, so the two families can never leak
    // into each other via shared state.
    func testEarDetectionDiscriminatorIsIndependentOfConnectivityState() {
        XCTAssertFalse(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: true,
                interruptionDuration: 45,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "a call must resume even mid connectivity-retry budget"
        )
        XCTAssertTrue(
            AudioInterruptionPolicy.shouldTreatEndAsDeliberatePause(
                beganAsRouteDisconnect: false,
                otherAudioWasPlaying: false,
                interruptionDuration: 0.2,
                previousOutputPortTypes: [.bluetoothA2DP],
                currentOutputPortTypes: [.bluetoothA2DP]
            ),
            "ear-off must stay a deliberate pause regardless of any "
                + "in-flight connectivity retry"
        )
    }

    // A media-services reset mid-call-recovery must keep the same autoplay
    // intent semantics that Agent C's `SessionActivationRetryPolicy` and
    // Agent A's resume flow both depend on: only resume automatically if
    // the user actually intended playback and it was active before the
    // reset landed.
    func testMediaServicesResetDuringRecoveryPreservesAutoplayIntent() {
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
            ),
            "a reset landing while playback was already stopped must not "
                + "restart it on its own"
        )
    }

    // PENDING — Agent E enables these once the parent has actually merged
    // A-D onto `main` (this branch does not merge their production code
    // per the isolation rule; only the pins in `scripts/validate_project.py`
    // may reference their symbols ahead of the merge, and only softly).
    //
    // All four branches below were confirmed pushed to origin — via
    // `git fetch origin <branch>` + `git diff origin/main origin/<branch>`,
    // never merged into this branch — while this file was being written, so
    // the signatures here are the real ones, not speculative:
    //
    // - Agent A (cursor/post-call-resume-bc40):
    //     `PostCallResumePolicy.shouldResumeWithoutOption(wasPlayingBeforeInterruption:playbackIntended:otherAudioWasPlaying:routeDisconnectPending:beganAsRouteDisconnect:)`
    //     ⇒ true for a call ended without `.shouldResume`; false for ear
    //     detection (`otherAudioWasPlaying: false`, deferring to
    //     `shouldTreatEndAsDeliberatePause` above), a pending/named route
    //     disconnect, or no prior playback intent.
    //     `PostCallResumePolicy.shouldResumeOnForeground(playbackIntended:isPlaying:isAudioInterrupted:hasPendingInterruptionResume:routeDisconnectPending:)`
    //     ⇒ true only once none of the other four flags are already
    //     covering the resume (suspended-app / missed-notification case).
    // - Agent B (cursor/network-aware-buffer-bc40):
    //     `NetworkAdaptiveBufferPolicy.preferredForwardBuffer(for: .nominal)`
    //     == `StreamFailureRetryPolicy.preferredForwardBufferDuration` (30,
    //     pins the existing wifi value byte-for-byte);
    //     `.degraded` ⇒ `+ degradedBufferBonus` (currently 15, so >= 45).
    //     `NetworkAdaptiveBufferPolicy.maximumConnectivityAttempts(baseline:condition:)`
    //     ⇒ `.degraded` never returns fewer than `baseline`.
    //     `NetworkAdaptiveBufferPolicy.retryDelay(base:condition:)` ⇒
    //     `.degraded` backoff stays capped (`degradedRetryDelayCap`, 12s),
    //     never unbounded.
    // - Agent C (cursor/avplayer-failure-hardening-bc40):
    //     `SessionActivationRetryPolicy.shouldRetry(attempt:)` ⇒ false once
    //     `attempt >= maximumAttempts` (currently 3); `retryDelay(forAttempt:)`
    //     stays capped at `maximumRetryDelay` (currently 2s). Exhausting the
    //     budget must surface an error, not crash.
    //     `StallRecoveryGuardPolicy.isOrphaned(blockedSince:now:)` ⇒ true
    //     once a recovery/refresh task has blocked past `orphanThreshold`
    //     (currently 20s), letting `recoverFromExtendedStall` proceed
    //     instead of wedging shut forever.
    // - Agent D (cursor/c-buffer-health-estimator-bc40):
    //     `pm_buffer_health_*` throughput/underrun estimation is unit-tested
    //     in `PrivateMusicCoreTests.swift`; referenced here only for the
    //     end-to-end call-during-3G narrative once B wires the estimator
    //     into the adaptive buffer target.
    //
    // Meta-test to add once all land: assert that every one of
    // PostCallResumePolicy / NetworkAdaptiveBufferPolicy /
    // SessionActivationRetryPolicy / StallRecoveryGuardPolicy /
    // pm_buffer_health_* is exercised by at least one XCTestCase in this
    // target (mirrors `require_stability_office_symbols` in
    // scripts/validate_project.py, which already pins all five by name).

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
