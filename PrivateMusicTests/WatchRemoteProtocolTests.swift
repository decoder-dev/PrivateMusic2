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
}
