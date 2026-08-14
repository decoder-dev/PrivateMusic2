import XCTest
@testable import PrivateMusic

final class WatchRemoteProtocolTests: XCTestCase {
    func testStateRoundTripsThroughApplicationContext() throws {
        let state = WatchRemoteState(
            trackID: "-1_42",
            title: "Track",
            artist: "Artist",
            artworkURL: URL(string: "https://example.com/art.jpg"),
            isPlaying: true,
            isBuffering: false,
            elapsed: 12.5,
            duration: 180,
            snapshotDate: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(WatchRemoteState(context: state.context), state)
    }

    func testEmptyStateHasNoTrackAndCanBeEncoded() {
        let decoded = WatchRemoteState(context: WatchRemoteState.empty.context)

        XCTAssertEqual(decoded, .empty)
        XCTAssertNil(decoded?.trackID)
    }

    func testCommandsHaveStableWireValues() {
        XCTAssertEqual(
            WatchRemoteCommand.togglePlayPause.rawValue,
            "togglePlayPause"
        )
        XCTAssertEqual(WatchRemoteCommand.next.rawValue, "next")
        XCTAssertEqual(WatchRemoteCommand.previous.rawValue, "previous")
        XCTAssertEqual(WatchRemoteCommand.likeCurrent.rawValue, "likeCurrent")
        XCTAssertEqual(
            WatchRemoteCommand.unlikeCurrent.rawValue,
            "unlikeCurrent"
        )
        XCTAssertEqual(
            WatchRemoteCommand.playQueueItem.rawValue,
            "playQueueItem"
        )
        XCTAssertEqual(WatchRemoteCommand.seek.rawValue, "seek")
    }

    func testLegacyStateDecodesWithoutLikeFields() throws {
        let legacy = """
        {
          "trackID": "1_2",
          "title": "Track",
          "artist": "Artist",
          "isPlaying": true,
          "isBuffering": false,
          "elapsed": 1,
          "duration": 10
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(WatchRemoteState.self, from: legacy)
        XCTAssertEqual(state.trackID, "1_2")
        XCTAssertFalse(state.isLiked)
        XCTAssertFalse(state.isMixQueue)
        XCTAssertEqual(state.queue, [])
        XCTAssertNil(state.currentQueueIndex)
    }

    func testPlayingStateInterpolatesElapsedTime() {
        let state = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 10,
            duration: 20,
            snapshotDate: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            state.displayedElapsed(
                at: Date(timeIntervalSince1970: 104.5)
            ),
            14.5
        )
        XCTAssertEqual(
            state.displayedElapsed(
                at: Date(timeIntervalSince1970: 200)
            ),
            20
        )
    }

    func testStateEqualityIgnoresSnapshotDate() {
        let earlier = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 10,
            duration: 20,
            snapshotDate: Date(timeIntervalSince1970: 100)
        )
        let later = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 10,
            duration: 20,
            snapshotDate: Date(timeIntervalSince1970: 104)
        )
        XCTAssertEqual(earlier, later)

        // Fine-grained elapsed drift stays equal; Watch interpolates locally.
        let withinBucket = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 11,
            duration: 20,
            snapshotDate: Date(timeIntervalSince1970: 104)
        )
        XCTAssertEqual(earlier, withinBucket)

        let nextBucket = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 21,
            duration: 20,
            snapshotDate: Date(timeIntervalSince1970: 104)
        )
        XCTAssertNotEqual(earlier, nextBucket)
    }

    func testCommandEnvelopeRoundTripsThroughMessage() {
        let envelope = WatchRemoteCommandEnvelope(
            command: .next,
            issuedAt: Date(timeIntervalSince1970: 123),
            trackID: "1_2"
        )

        XCTAssertEqual(
            WatchRemoteCommandEnvelope(message: envelope.message),
            envelope
        )
    }

    func testCommandEnvelopeRejectsStaleOrWrongTrackCommands() {
        let envelope = WatchRemoteCommandEnvelope(
            command: .next,
            issuedAt: Date(timeIntervalSince1970: 100),
            trackID: "1_2"
        )

        XCTAssertTrue(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2"
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 116),
                currentTrackID: "1_2"
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "9_9"
            )
        )
    }

    func testQueueRoundTripsThroughApplicationContext() throws {
        let queue = [
            WatchQueueItem(trackID: "1_1", title: "One", artist: "A"),
            WatchQueueItem(trackID: "1_2", title: "Two", artist: "B"),
            WatchQueueItem(trackID: "1_3", title: "Three", artist: "C"),
        ]
        let state = WatchRemoteState(
            trackID: "1_2",
            title: "Two",
            artist: "B",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 4,
            duration: 40,
            snapshotDate: Date(timeIntervalSince1970: 50),
            isLiked: true,
            isMixQueue: true,
            queue: queue,
            currentQueueIndex: 1
        )

        XCTAssertEqual(WatchRemoteState(context: state.context), state)
        XCTAssertEqual(
            WatchRemoteState(context: state.context)?.queue,
            queue
        )
        XCTAssertEqual(
            WatchRemoteState(context: state.context)?.currentQueueIndex,
            1
        )
    }

    func testLegacyStateDecodesWithoutQueue() throws {
        let legacy = """
        {
          "trackID": "1_2",
          "title": "Track",
          "artist": "Artist",
          "isPlaying": true,
          "isBuffering": false,
          "elapsed": 1,
          "duration": 10,
          "isLiked": true,
          "isMixQueue": true
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(WatchRemoteState.self, from: legacy)
        XCTAssertEqual(state.queue, [])
        XCTAssertNil(state.currentQueueIndex)
        XCTAssertTrue(state.isLiked)
        XCTAssertTrue(state.isMixQueue)
    }

    func testUnlikeCommandEnvelopeRoundTripsAndBindsToCurrentTrack() {
        let envelope = WatchRemoteCommandEnvelope(
            command: .unlikeCurrent,
            issuedAt: Date(timeIntervalSince1970: 100),
            trackID: "1_2"
        )

        XCTAssertEqual(
            WatchRemoteCommandEnvelope(message: envelope.message),
            envelope
        )
        XCTAssertTrue(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2"
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "9_9"
            )
        )
    }

    func testPlayQueueItemValidatesTargetInQueueNotCurrentTrack() {
        let envelope = WatchRemoteCommandEnvelope(
            command: .playQueueItem,
            issuedAt: Date(timeIntervalSince1970: 100),
            trackID: "1_9"
        )
        let queued = ["1_2", "1_9", "1_3"]

        XCTAssertTrue(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2",
                queuedTrackIDs: queued
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_9",
                queuedTrackIDs: queued
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2"
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2",
                queuedTrackIDs: ["1_2", "1_3"]
            )
        )
    }

    func testQueueSnapshotPolicyCapsWindowAtMaxCount() {
        XCTAssertEqual(WatchQueueSnapshotPolicy.maxCount, 20)

        let items = (0..<40).map { index in
            WatchQueueItem(
                trackID: "id_\(index)",
                title: "T\(index)",
                artist: "A"
            )
        }

        let start = WatchQueueSnapshotPolicy.window(
            items: items,
            currentIndex: 0
        )
        XCTAssertEqual(start.items.count, WatchQueueSnapshotPolicy.maxCount)
        XCTAssertEqual(start.currentIndex, 0)
        XCTAssertEqual(start.items.first?.trackID, "id_0")
        XCTAssertEqual(start.items.last?.trackID, "id_19")

        let end = WatchQueueSnapshotPolicy.window(
            items: items,
            currentIndex: 39
        )
        XCTAssertEqual(end.items.count, WatchQueueSnapshotPolicy.maxCount)
        XCTAssertEqual(end.currentIndex, 19)
        XCTAssertEqual(end.items.first?.trackID, "id_20")
        XCTAssertEqual(end.items.last?.trackID, "id_39")

        let middle = WatchQueueSnapshotPolicy.window(
            items: items,
            currentIndex: 20
        )
        XCTAssertEqual(middle.items.count, WatchQueueSnapshotPolicy.maxCount)
        XCTAssertEqual(middle.currentIndex, 10)
        XCTAssertEqual(middle.items[10].trackID, "id_20")
        XCTAssertTrue(middle.items.contains { $0.trackID == "id_20" })

        let short = WatchQueueSnapshotPolicy.window(
            items: Array(items.prefix(5)),
            currentIndex: 2
        )
        XCTAssertEqual(short.items.count, 5)
        XCTAssertEqual(short.currentIndex, 2)

        let missingCurrent = WatchQueueSnapshotPolicy.window(
            items: items,
            currentIndex: nil
        )
        XCTAssertEqual(
            missingCurrent.items.count,
            WatchQueueSnapshotPolicy.maxCount
        )
        XCTAssertNil(missingCurrent.currentIndex)

        let empty = WatchQueueSnapshotPolicy.window(
            items: [WatchQueueItem](),
            currentIndex: 0
        )
        XCTAssertEqual(empty.items, [])
        XCTAssertNil(empty.currentIndex)
    }

    func testQueueChangesBreakStateEquality() {
        let base = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 10,
            duration: 20,
            queue: [
                WatchQueueItem(trackID: "1_2", title: "Track", artist: "Artist")
            ],
            currentQueueIndex: 0
        )
        let differentQueue = WatchRemoteState(
            trackID: "1_2",
            title: "Track",
            artist: "Artist",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 10,
            duration: 20,
            queue: [
                WatchQueueItem(trackID: "1_2", title: "Track", artist: "Artist"),
                WatchQueueItem(trackID: "1_3", title: "Next", artist: "Artist"),
            ],
            currentQueueIndex: 0
        )
        XCTAssertNotEqual(base, differentQueue)
    }

    func testSeekEnvelopeRoundTripsAndBindsToCurrentTrack() {
        let envelope = WatchRemoteCommandEnvelope(
            command: .seek,
            issuedAt: Date(timeIntervalSince1970: 100),
            trackID: "1_2",
            seekTime: 45
        )

        XCTAssertEqual(
            WatchRemoteCommandEnvelope(message: envelope.message),
            envelope
        )
        XCTAssertTrue(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2"
            )
        )
        XCTAssertFalse(
            envelope.isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "9_9"
            )
        )
        XCTAssertFalse(
            WatchRemoteCommandEnvelope(
                command: .seek,
                issuedAt: Date(timeIntervalSince1970: 100),
                trackID: "1_2"
            ).isValid(
                at: Date(timeIntervalSince1970: 110),
                currentTrackID: "1_2"
            )
        )
    }

    func testLegacyCommandEnvelopeDecodesWithoutSeekTime() throws {
        let encoded = try JSONEncoder().encode(
            WatchRemoteCommandEnvelope(
                command: .next,
                issuedAt: Date(timeIntervalSince1970: 100),
                trackID: "1_2"
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "seekTime")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let envelope = try JSONDecoder().decode(
            WatchRemoteCommandEnvelope.self,
            from: legacy
        )
        XCTAssertEqual(envelope.command, .next)
        XCTAssertNil(envelope.seekTime)
        XCTAssertEqual(envelope.trackID, "1_2")
    }
}
