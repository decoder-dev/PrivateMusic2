import XCTest
@testable import PrivateMusic

final class PlaylistDecodingTests: XCTestCase {
    func testDecodedPlaylistKeepsVKSourceAttribution() throws {
        let json = """
        {
          "id": 17,
          "owner_id": 42,
          "title": "Night Drive",
          "description": "Imported playlist",
          "count": 12,
          "photo_600": "https://example.com/playlist.jpg"
        }
        """

        let playlist = try JSONDecoder().decode(
            Playlist.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(playlist.source, .vk)
        XCTAssertEqual(
            playlist.source.title,
            L10n.text("VK Музыка")
        )
        XCTAssertEqual(playlist.source.shortTitle, "VK")
        XCTAssertEqual(
            playlist.artworkURL?.absoluteString,
            "https://example.com/playlist.jpg"
        )
    }
}
