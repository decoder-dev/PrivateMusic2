import XCTest
@testable import PrivateMusic

final class PlaybackClockPolicyTests: XCTestCase {
    func testClockTicksFastOnScreenAndSlowInTheBackground() {
        XCTAssertEqual(
            PlaybackClockPolicy.interval(interfaceActive: true, crossfadeEnabled: false),
            PlaybackClockPolicy.activeInterval
        )
        XCTAssertEqual(
            PlaybackClockPolicy.interval(interfaceActive: false, crossfadeEnabled: false),
            PlaybackClockPolicy.backgroundInterval
        )
    }

    func testCrossfadeKeepsTheFastClockInTheBackground() {
        XCTAssertEqual(
            PlaybackClockPolicy.interval(interfaceActive: false, crossfadeEnabled: true),
            PlaybackClockPolicy.activeInterval
        )
    }

    func testCrossfadeClockOnlyArmsNearTheEndWithLookahead() {
        XCTAssertFalse(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: 120, fadeSeconds: 0.55))
        XCTAssertTrue(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: 3.25, fadeSeconds: 0.55))
        XCTAssertFalse(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: false, remaining: 1, fadeSeconds: 0.55))
        XCTAssertFalse(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: .nan, fadeSeconds: 0.55))
        XCTAssertFalse(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: 0, fadeSeconds: 0.55))
        XCTAssertTrue(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: 12.7, fadeSeconds: 10))
        XCTAssertFalse(PlaybackClockPolicy.needsFastCrossfadeClock(eligible: true, remaining: 12.8, fadeSeconds: 10))
    }

    func testCoarseTickCannotSkipPreparationForSupportedFadeDurations() {
        for fade in [0.5, 0.55, 2, 5, 10] {
            let preparation = max(PlaybackTransitionPolicy.prepareLeadIn, fade + 0.7)
            // The last coarse tick outside the arm window advances at most 2 s.
            let nextRemaining = preparation + PlaybackClockPolicy.backgroundInterval + 0.01
                - PlaybackClockPolicy.backgroundInterval
            XCTAssertTrue(PlaybackClockPolicy.needsFastCrossfadeClock(
                eligible: true, remaining: nextRemaining, fadeSeconds: fade))
            XCTAssertGreaterThan(nextRemaining, fade)
        }
    }

    func testSlowClockStillCreditsListenedTime() {
        let tick = PlaybackClockPolicy.backgroundInterval
        XCTAssertGreaterThanOrEqual(
            PlaybackClockPolicy.maximumListenDelta(forInterval: tick),
            tick
        )
        // A seek-sized jump is still rejected.
        XCTAssertLessThan(
            PlaybackClockPolicy.maximumListenDelta(forInterval: tick),
            30
        )
        XCTAssertEqual(
            PlaybackClockPolicy.maximumListenDelta(
                forInterval: PlaybackClockPolicy.activeInterval
            ),
            1.5
        )
    }

    func testPersistenceFiresEveryPeriodEvenWhenTicksSkipExactMultiples() {
        // 2 s ticks never land on an odd multiple of 15.
        var last = -1
        var persisted: [Int] = []
        for second in stride(from: 2, through: 62, by: 2) {
            if PlaybackClockPolicy.shouldPersist(wholeSecond: second, lastPersistedSecond: last) {
                persisted.append(second)
                last = second
            }
        }
        XCTAssertEqual(persisted, [16, 32, 48, 64].filter { $0 <= 62 })
        XCTAssertFalse(PlaybackClockPolicy.shouldPersist(wholeSecond: 0, lastPersistedSecond: -1))
    }

    func testPersistsAgainAfterSeekingBackwards() {
        XCTAssertFalse(PlaybackClockPolicy.shouldPersist(wholeSecond: 95, lastPersistedSecond: 100))
        XCTAssertTrue(PlaybackClockPolicy.shouldPersist(wholeSecond: 20, lastPersistedSecond: 100))
    }
}
