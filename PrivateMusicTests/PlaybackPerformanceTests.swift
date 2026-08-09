import XCTest
@testable import PrivateMusic

@MainActor
final class PlaybackProgressModelTests: XCTestCase {
    func testUpdatesIgnoreSubThresholdDeltas() {
        let progress = PlaybackProgressModel()
        progress.update(1.0, force: true)
        progress.update(1.1)
        XCTAssertEqual(progress.elapsedTime, 1.0, accuracy: 0.000_1)
        progress.update(1.3)
        XCTAssertEqual(progress.elapsedTime, 1.3, accuracy: 0.000_1)
    }

    func testForceResetPublishesImmediately() {
        let progress = PlaybackProgressModel()
        progress.update(12, force: true)
        progress.reset(to: 0)
        XCTAssertEqual(progress.elapsedTime, 0, accuracy: 0.000_1)
    }
}

final class RemoteCommandCoalescingTests: XCTestCase {
    func testPauseThenToggleStaysPaused() {
        let merged = RemoteCommandCoalescing.merge(
            pending: .pause,
            incoming: .toggle
        )
        XCTAssertEqual(merged, .pause)
    }

    func testPlayThenToggleStaysPlaying() {
        let merged = RemoteCommandCoalescing.merge(
            pending: .play,
            incoming: .toggle
        )
        XCTAssertEqual(merged, .play)
    }

    func testPlayThenPauseKeepsLatest() {
        XCTAssertEqual(
            RemoteCommandCoalescing.merge(pending: .play, incoming: .pause),
            .pause
        )
    }

    func testSeekYieldsToTransport() {
        XCTAssertEqual(
            RemoteCommandCoalescing.merge(
                pending: .seek(12),
                incoming: .play
            ),
            .play
        )
    }
}

final class PlaybackArtworkPerformancePolicyTests: XCTestCase {
    func testPlayerBackgroundUsesSmallBlurSource() {
        XCTAssertLessThanOrEqual(
            PlayerArtworkBackgroundPolicy.maxPixelSize,
            320
        )
        XCTAssertLessThanOrEqual(
            PlayerArtworkBackgroundPolicy.blurRadius,
            48
        )
    }

    func testNowPlayingArtworkIsBoundedForLockScreen() {
        XCTAssertEqual(NowPlayingArtworkPolicy.maxPixelSize, 600)
    }
}

final class WatchStatePushCoalescingPolicyTests: XCTestCase {
    func testRegularBurstRemainsNonForced() {
        XCTAssertFalse(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: false,
                incoming: false
            )
        )
    }

    func testForceRemainsStickyAcrossBurst() {
        XCTAssertTrue(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: true,
                incoming: false
            )
        )
        XCTAssertTrue(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: false,
                incoming: true
            )
        )
    }
}
