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
            elapsed: 12.5,
            duration: 180
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
    }
}
