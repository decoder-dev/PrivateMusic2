import XCTest
@testable import PrivateMusic

final class TrackDecodingTests: XCTestCase {
    func testDecodesVKTrack() throws {
        let json = """
        {
          "id": 42,
          "owner_id": 7,
          "title": "No Trace",
          "artist": "Private Music",
          "duration": 185,
          "url": "https://example.com/audio.mp3",
          "access_key": "sample",
          "album": {
            "thumb": {
              "photo_600": "https://example.com/cover.jpg"
            }
          }
        }
        """

        let track = try JSONDecoder().decode(
            Track.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(track.id, "7_42")
        XCTAssertEqual(track.title, "No Trace")
        XCTAssertEqual(track.duration, 185)
        XCTAssertEqual(
            track.artworkURL?.absoluteString,
            "https://example.com/cover.jpg"
        )
    }
}

