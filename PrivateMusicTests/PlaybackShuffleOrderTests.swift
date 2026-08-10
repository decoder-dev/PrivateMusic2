import XCTest
@testable import PrivateMusic

final class PlaybackShuffleOrderTests: XCTestCase {
    func testShufflePutsTheCurrentTrackFirstAndKeepsEveryTrack() {
        let queue = (1...8).map(track)

        let shuffled = PlaybackShuffleOrder.shuffled(
            queue,
            keeping: track(5)
        )

        XCTAssertEqual(shuffled.first?.id, "1_5")
        XCTAssertEqual(Set(shuffled.map(\.id)), Set(queue.map(\.id)))
        XCTAssertEqual(shuffled.count, queue.count)
    }

    // The reported defect: turning shuffle off used to freeze the shuffled
    // order, so Медиатека never played «по очереди» again.
    func testTurningShuffleOffRebuildsTheSourceOrder() {
        let source = (1...5).map(track)
        let shuffled = [track(4), track(1), track(5), track(2), track(3)]

        let restored = PlaybackShuffleOrder.restored(
            queue: shuffled,
            sourceOrder: source
        )

        XCTAssertEqual(restored.map(\.id), source.map(\.id))
    }

    func testRestoreDropsTracksTheQueueNoLongerHolds() {
        let source = (1...5).map(track)
        let shuffled = [track(5), track(2), track(1)]

        let restored = PlaybackShuffleOrder.restored(
            queue: shuffled,
            sourceOrder: source
        )

        XCTAssertEqual(restored.map(\.id), ["1_1", "1_2", "1_5"])
    }

    func testRestoreKeepsTracksTheQueueGainedWhileShuffled() {
        let source = (1...3).map(track)
        // 90 arrived through «Играть следующим», 91 through a mix refill.
        let shuffled = [track(2), track(90), track(1), track(91), track(3)]

        let restored = PlaybackShuffleOrder.restored(
            queue: shuffled,
            sourceOrder: source
        )

        XCTAssertEqual(
            restored.map(\.id),
            ["1_1", "1_2", "1_3", "1_90", "1_91"]
        )
    }

    func testRestoreWithoutASnapshotLeavesTheQueueAlone() {
        let queue = [track(3), track(1), track(2)]

        XCTAssertEqual(
            PlaybackShuffleOrder.restored(queue: queue, sourceOrder: [])
                .map(\.id),
            queue.map(\.id)
        )
    }

    func testRestoreNeverDuplicatesARepeatedSnapshotEntry() {
        let restored = PlaybackShuffleOrder.restored(
            queue: [track(2), track(1)],
            sourceOrder: [track(1), track(2), track(1)]
        )

        XCTAssertEqual(restored.map(\.id), ["1_1", "1_2"])
    }

    private func track(_ id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Track \(id)",
            artist: "Artist",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
