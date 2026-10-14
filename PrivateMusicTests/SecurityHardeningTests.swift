import XCTest
@testable import PrivateMusic

final class SecurityHardeningTests: XCTestCase {
    // MARK: Retry-After

    func testRetryDelayIgnoresNonFiniteAndNegativeServerValues() {
        for hostile in ["nan", "NaN", "inf", "-inf", "-5", "1e999", "", "soon"] {
            let delay = APIRequestPolicy.retryDelay(attempt: 0, retryAfter: hostile, jitter: 1)
            XCTAssertTrue(delay.isFinite, hostile)
            XCTAssertGreaterThanOrEqual(delay, 0.2, hostile)
            XCTAssertLessThanOrEqual(delay, 8, hostile)
            // Falls back to the exponential schedule: 0.55 s on the first retry.
            XCTAssertEqual(delay, 0.55, accuracy: 0.001, hostile)
        }
    }

    func testRetryDelayHonoursAnnouncedSecondsWithinBounds() {
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: 0, retryAfter: "3", jitter: 1), 3)
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: 0, retryAfter: " 2 ", jitter: 1), 2)
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: 0, retryAfter: "120", jitter: 1), 8)
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: 0, retryAfter: "0", jitter: 1), 0.2)
    }

    func testRetryDelayExponentialIsCapped() {
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: 40, retryAfter: nil, jitter: 1), 4)
        XCTAssertEqual(APIRequestPolicy.retryDelay(attempt: -3, retryAfter: nil, jitter: 1), 0.55,
                       accuracy: 0.001)
    }

    // MARK: Request URL

    func testRequestPathStaysOnTheAPIHost() {
        let base = URL(string: "https://api.vk.ru")!
        XCTAssertEqual(
            APIRequestPolicy.resolve(path: "/method/audio.get", against: base)?.absoluteString,
            "https://api.vk.ru/method/audio.get"
        )
        for hostile in [
            "https://evil.example/method/audio.get",
            "//evil.example/method/audio.get",
            "http://api.vk.ru/method/audio.get",
            "https://api.vk.ru@evil.example/x",
            "https://user:pw@api.vk.ru/x"
        ] {
            XCTAssertNil(APIRequestPolicy.resolve(path: hostile, against: base), hostile)
        }
    }

    func testRedirectsAreFollowedOnlyWithinTheSameHTTPSHost() {
        let origin = URL(string: "https://api.vk.ru/method/audio.get")
        XCTAssertTrue(VKAPIRedirectPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://api.vk.ru/method/audio.get2")))
        XCTAssertFalse(VKAPIRedirectPolicy.allowsRedirect(
            from: origin, to: URL(string: "https://evil.example/")))
        XCTAssertFalse(VKAPIRedirectPolicy.allowsRedirect(
            from: origin, to: URL(string: "http://api.vk.ru/")))
        XCTAssertFalse(VKAPIRedirectPolicy.allowsRedirect(from: origin, to: nil))
    }

    // MARK: Log redaction

    func testRedactionCoversSignedURLsAndJSONBodies() {
        let samples: [(String, String)] = [
            ("https://cs1.vkuseraudio.net/a/index.m3u8?extra=SECRETVALUE123&siren=1", "SECRETVALUE123"),
            ("GET /x?sig=abcdef0123456789&v=5", "abcdef0123456789"),
            ("{\"access_token\":\"vk1.a.SECRETTOKEN\",\"user_id\":1}", "SECRETTOKEN"),
            ("{\"password\": \"hunter2hunter2\"}", "hunter2hunter2"),
            ("sent Bearer abcdef.ghijkl.mnopqr to host", "abcdef.ghijkl.mnopqr")
        ]
        for (line, secret) in samples {
            let redacted = AppLogRedaction.redact(line)
            XCTAssertFalse(redacted.contains(secret), redacted)
            XCTAssertTrue(redacted.contains("<redacted>"), redacted)
        }
    }

    func testRedactionKeepsOrdinaryDiagnostics() {
        let line = "POST /method/audio.get status=200 bytes=2048 duration=312ms"
        XCTAssertEqual(AppLogRedaction.redact(line), line)
    }
}
