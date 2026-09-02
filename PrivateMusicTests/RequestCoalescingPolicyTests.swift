import XCTest
@testable import PrivateMusic

/// Counted off one cold launch in a device log, on constrained cellular:
/// `audio.get&offset=0` sent four times inside the same minute at ~250 KB
/// each, `audio.getRecommendations` seven times at ~270 KB, `users.get`
/// three times. 2.7 MB for a launch, most of it the same bytes again.
final class RequestCoalescingPolicyTests: XCTestCase {
    private func body(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - What may share an answer

    /// Every method the log caught duplicating itself.
    func testTheReadsThatDuplicatedThemselvesMayShare() {
        for path in [
            "/method/audio.get",
            "/method/audio.getById",
            "/method/audio.getPlaylists",
            "/method/audio.getRecommendations",
            "/method/users.get",
            "/method/catalog.getAudio",
            "/method/catalog.getSection",
            "/method/audio.search",
            "/method/audio.searchArtists"
        ] {
            XCTAssertTrue(
                RequestCoalescingPolicy.sharesAnswer(path: path),
                "\(path) is a read"
            )
        }
    }

    /// Two identical adds are two intents, not one answer asked for twice.
    /// Getting this wrong silently drops a user's action, which is far
    /// worse than the duplicate request this policy exists to remove.
    func testWritesNeverShareAnAnswer() {
        for path in [
            "/method/audio.add",
            "/method/audio.delete",
            "/method/audio.edit",
            "/method/audio.restore",
            "/method/audio.reorder",
            "/method/audio.addToPlaylist",
            "/method/audio.setBroadcast",
            "/method/audio.createPlaylist"
        ] {
            XCTAssertFalse(
                RequestCoalescingPolicy.sharesAnswer(path: path),
                "\(path) changes something"
            )
        }
    }

    /// A path shaped in a way this rule cannot read is treated as a write:
    /// an extra request costs data, a swallowed one costs correctness.
    func testAnUnrecognisablePathIsTreatedAsAWrite() {
        XCTAssertFalse(RequestCoalescingPolicy.sharesAnswer(path: ""))
        XCTAssertFalse(RequestCoalescingPolicy.sharesAnswer(path: "/method/"))
        XCTAssertFalse(
            RequestCoalescingPolicy.sharesAnswer(path: "/method/execute")
        )
    }

    // MARK: - What counts as the same request

    func testTheSameReadWithTheSameParametersSharesOneKey() {
        let form = body("access_token=abc&count=100&offset=0")

        XCTAssertEqual(
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: form,
                retryPolicy: .transient
            ),
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: form,
                retryPolicy: .transient
            )
        )
    }

    /// The paging walk that produced most of those bytes asks the same
    /// method over and over with a different offset. Those are different
    /// answers and must stay different requests.
    func testADifferentPageIsADifferentRequest() {
        XCTAssertNotEqual(
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: body("access_token=abc&count=100&offset=0"),
                retryPolicy: .transient
            ),
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: body("access_token=abc&count=100&offset=100"),
                retryPolicy: .transient
            )
        )
    }

    /// A request signed by a token that has since rotated is not the same
    /// request — sharing across the exchange would hand back an answer
    /// fetched with credentials that are already gone.
    func testADifferentTokenIsADifferentRequest() {
        XCTAssertNotEqual(
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: body("access_token=old&offset=0"),
                retryPolicy: .transient
            ),
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: body("access_token=new&offset=0"),
                retryPolicy: .transient
            )
        )
    }

    /// Playback recovery deliberately runs on a shorter timeout and does not
    /// retry, so it must not be parked behind a leisurely catalog fetch of
    /// the same track.
    func testADifferentRetryPolicyIsADifferentRequest() {
        let form = body("access_token=abc&audios=1_2")

        XCTAssertNotEqual(
            RequestCoalescingPolicy.key(
                path: "/method/audio.getById",
                body: form,
                retryPolicy: .transient
            ),
            RequestCoalescingPolicy.key(
                path: "/method/audio.getById",
                body: form,
                retryPolicy: .playbackRecovery
            )
        )
    }

    func testAWriteHasNoKeyToShare() {
        XCTAssertNil(
            RequestCoalescingPolicy.key(
                path: "/method/audio.add",
                body: body("access_token=abc&audio_id=1"),
                retryPolicy: .transient
            )
        )
    }

    func testARequestWithNoBodyHasNoKey() {
        XCTAssertNil(
            RequestCoalescingPolicy.key(
                path: "/method/audio.get",
                body: nil,
                retryPolicy: .transient
            )
        )
    }
}
