import XCTest
@testable import PrivateMusic

final class NowPlayingUserActivityTests: XCTestCase {
    func testActivityTypeAndUserInfoAreStable() {
        let track = Track(
            trackID: 42,
            ownerID: 7,
            title: "Track",
            artist: "Artist",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )

        XCTAssertEqual(
            NowPlayingUserActivityPolicy.activityType,
            "com.dec.privatemusic2.now-playing"
        )
        XCTAssertEqual(
            NowPlayingUserActivityPolicy.activityTitle(for: track),
            "Artist — Track"
        )
        XCTAssertEqual(
            NowPlayingUserActivityPolicy.userInfo(for: track)["trackID"],
            "7_42"
        )
        XCTAssertEqual(
            NowPlayingUserActivityPolicy.trackID(
                fromUserInfo: NowPlayingUserActivityPolicy.userInfo(for: track)
            ),
            "7_42"
        )
    }

    func testPresentsPlayerOnlyWhenSomethingIsPlaying() {
        XCTAssertFalse(
            NowPlayingUserActivityPolicy.shouldPresentPlayer(
                currentTrackID: nil
            )
        )
        XCTAssertTrue(
            NowPlayingUserActivityPolicy.shouldPresentPlayer(
                currentTrackID: "7_42"
            )
        )
    }

    func testResumesMatchingQueueItemAndSkipsCurrent() {
        let queue = ["1_1", "7_42", "1_3"]
        XCTAssertEqual(
            NowPlayingUserActivityPolicy.queueIndexToResume(
                activityTrackID: "7_42",
                queueIDs: queue,
                currentIndex: 0
            ),
            1
        )
        XCTAssertNil(
            NowPlayingUserActivityPolicy.queueIndexToResume(
                activityTrackID: "7_42",
                queueIDs: queue,
                currentIndex: 1
            )
        )
        XCTAssertNil(
            NowPlayingUserActivityPolicy.queueIndexToResume(
                activityTrackID: "9_9",
                queueIDs: queue,
                currentIndex: 0
            )
        )
    }
}
