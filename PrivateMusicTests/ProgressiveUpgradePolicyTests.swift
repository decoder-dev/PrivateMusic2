import AVFoundation
import XCTest
@testable import PrivateMusic

/// Read off a three-day device log on 3.28.87: 52 tracks, 52 identical
/// `item failure … Запрошенный URL не был обнаружен на этом сервере`
/// entries, each one the `…/HASH/index.m3u8` → `…/HASH.mp3` rewrite being
/// tried again against a CDN that had already refused it 51 times.
final class ProgressiveUpgradePolicyTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("bad test URL \(string)")
        }
        return url
    }

    // MARK: - Which CDN the lesson is filed under

    /// The host in the log was `cs9-4v4.vkuseraudio.ru`, and VK hands out a
    /// different shard almost every track. Filing the refusal under the full
    /// host would mean paying for the same 404 once per shard.
    func testShardsOfTheSameCDNShareOneLesson() {
        let first = ProgressiveUpgradePolicy.cdnKey(
            for: url("https://cs9-4v4.vkuseraudio.ru/a/b/index.m3u8")
        )
        let second = ProgressiveUpgradePolicy.cdnKey(
            for: url("https://psv4.vkuseraudio.ru/x/y/index.m3u8")
        )

        XCTAssertEqual(first, "vkuseraudio.ru")
        XCTAssertEqual(first, second)
    }

    /// `.ru` and `.net` are separate deployments and are allowed to answer
    /// differently.
    func testDifferentDomainsAreLearnedSeparately() {
        XCTAssertNotEqual(
            ProgressiveUpgradePolicy.cdnKey(
                for: url("https://cs9.vkuseraudio.ru/a/index.m3u8")
            ),
            ProgressiveUpgradePolicy.cdnKey(
                for: url("https://cs9.vkuseraudio.net/a/index.m3u8")
            )
        )
    }

    func testAHostWithoutASubdomainIsKeptWhole() {
        XCTAssertEqual(
            ProgressiveUpgradePolicy.cdnKey(for: url("https://vk.com/a")),
            "vk.com"
        )
    }

    func testAURLWithNoHostTeachesNothing() {
        XCTAssertNil(
            ProgressiveUpgradePolicy.cdnKey(for: url("file:///tmp/a.mp3"))
        )
        XCTAssertTrue(
            ProgressiveUpgradePolicy.allowsUpgrade(
                from: url("file:///tmp/a.mp3"),
                refusedCDNs: ["vkuseraudio.ru"]
            ),
            "a local file has no CDN to blame"
        )
    }

    // MARK: - Acting on the lesson

    func testAnUntriedCDNStillGetsTheUpgrade() {
        XCTAssertTrue(
            ProgressiveUpgradePolicy.allowsUpgrade(
                from: url("https://cs9-4v4.vkuseraudio.ru/a/index.m3u8"),
                refusedCDNs: []
            )
        )
    }

    func testARefusedCDNIsNotAskedAgainOnAnyShard() {
        let refused: Set<String> = ["vkuseraudio.ru"]

        XCTAssertFalse(
            ProgressiveUpgradePolicy.allowsUpgrade(
                from: url("https://cs9-4v4.vkuseraudio.ru/a/index.m3u8"),
                refusedCDNs: refused
            )
        )
        XCTAssertFalse(
            ProgressiveUpgradePolicy.allowsUpgrade(
                from: url("https://cs1-7v2.vkuseraudio.ru/b/index.m3u8"),
                refusedCDNs: refused
            ),
            "a different shard of the same CDN"
        )
        XCTAssertTrue(
            ProgressiveUpgradePolicy.allowsUpgrade(
                from: url("https://cs9.vkuseraudio.net/c/index.m3u8"),
                refusedCDNs: refused
            ),
            "an untried CDN keeps its chance"
        )
    }

    // MARK: - What counts as a refusal

    /// The log's error, verbatim: HTTP 404 reaches AVFoundation as
    /// `NSURLErrorFileDoesNotExist`. Nothing else means "there is no MP3
    /// beside the playlist".
    func testAMissingFileIsARefusal() {
        XCTAssertTrue(
            ProgressiveUpgradePolicy.refusalIsConclusive(
                URLError(.fileDoesNotExist)
            )
        )
    }

    /// A tunnel is not an answer. Remembering one would cost the upgrade for
    /// the rest of the session over a bad minute.
    func testATransientNetworkFailureTeachesNothing() {
        for code: URLError.Code in [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .resourceUnavailable,
            .dataNotAllowed
        ] {
            XCTAssertFalse(
                ProgressiveUpgradePolicy.refusalIsConclusive(URLError(code)),
                "\(code) must not disable the upgrade"
            )
        }
        XCTAssertFalse(ProgressiveUpgradePolicy.refusalIsConclusive(nil))
    }

    /// AVFoundation usually hands the URL error straight through, but wraps
    /// it when the failure arrives from an asset load.
    func testAWrappedMissingFileIsStillARefusal() {
        let wrapped = NSError(
            domain: AVFoundationErrorDomain,
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: URLError(.fileDoesNotExist)]
        )

        XCTAssertTrue(ProgressiveUpgradePolicy.refusalIsConclusive(wrapped))
    }

    func testAWrappedTimeoutIsStillNotARefusal() {
        let wrapped = NSError(
            domain: AVFoundationErrorDomain,
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]
        )

        XCTAssertFalse(ProgressiveUpgradePolicy.refusalIsConclusive(wrapped))
    }

    // MARK: - Calling off the refresh hunt

    /// The second half of the same log: after each 404 the app spent an
    /// `audio.getById` asking VK for a progressive payload, and got HLS back
    /// every time — 52 requests on a constrained cellular link that could
    /// not have changed the outcome.
    func testVKAnsweringHLSThreeTimesEndsTheHunt() {
        let hls = url("https://cs9.vkuseraudio.ru/a/index.m3u8")
        var attempts = 0

        for expected in 1...ProgressiveUpgradePolicy.hlsRefreshPatience {
            XCTAssertTrue(
                ProgressiveUpgradePolicy.shouldKeepHuntingForProgressive(
                    hlsOnlyRefreshes: attempts
                ),
                "attempt \(expected) is still worth a request"
            )
            attempts = ProgressiveUpgradePolicy.hlsRefreshAttemptsAfter(
                previous: attempts,
                refreshedURL: hls
            )
            XCTAssertEqual(attempts, expected)
        }

        XCTAssertFalse(
            ProgressiveUpgradePolicy.shouldKeepHuntingForProgressive(
                hlsOnlyRefreshes: attempts
            )
        )
    }

    /// One progressive payload proves the hunt works on this account, so the
    /// budget starts over rather than staying spent.
    func testAProgressivePayloadResetsThePatience() {
        XCTAssertEqual(
            ProgressiveUpgradePolicy.hlsRefreshAttemptsAfter(
                previous: 2,
                refreshedURL: url("https://cs9.vkuseraudio.ru/a/b.mp3")
            ),
            0
        )
        XCTAssertTrue(
            ProgressiveUpgradePolicy.shouldKeepHuntingForProgressive(
                hlsOnlyRefreshes: 0
            )
        )
    }

    /// A refresh that returned no stream at all failed for its own reasons;
    /// it is not evidence about what VK serves.
    func testAnEmptyPayloadDoesNotCountAgainstThePatience() {
        XCTAssertEqual(
            ProgressiveUpgradePolicy.hlsRefreshAttemptsAfter(
                previous: 2,
                refreshedURL: nil
            ),
            2
        )
    }
}
