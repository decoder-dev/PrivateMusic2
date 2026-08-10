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

    func testGeneratedMosaicCoverIsDecodedFromThumbs() throws {
        // VK ships the auto-generated cover of playlists without an
        // uploaded photo (including «Мне нравится») under `thumbs`.
        let json = """
        {
          "id": 1,
          "owner_id": 42,
          "title": "Мне нравится",
          "count": 118,
          "thumbs": [
            {
              "photo_600": "https://example.com/mosaic-600.jpg",
              "photo_300": "https://example.com/mosaic-300.jpg"
            }
          ]
        }
        """

        let playlist = try JSONDecoder().decode(
            Playlist.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(
            playlist.artworkURL?.absoluteString,
            "https://example.com/mosaic-600.jpg"
        )
    }

    func testNestedThumbCoverStillWins() throws {
        let json = """
        {
          "id": 2,
          "owner_id": 42,
          "title": "Дорога",
          "count": 4,
          "thumb": { "photo_270": "https://example.com/thumb-270.jpg" },
          "thumbs": [
            { "photo_600": "https://example.com/mosaic-600.jpg" }
          ]
        }
        """

        let playlist = try JSONDecoder().decode(
            Playlist.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(
            playlist.artworkURL?.absoluteString,
            "https://example.com/thumb-270.jpg"
        )
    }

    func testPlaylistRoundTripsThroughItsOwnEncoding() throws {
        let json = """
        {
          "id": 17,
          "owner_id": -42,
          "title": "Night Drive",
          "count": 12,
          "photo_600": "https://example.com/playlist.jpg",
          "access_key": "abc"
        }
        """

        let playlist = try JSONDecoder().decode(
            Playlist.self,
            from: Data(json.utf8)
        )
        let restored = try JSONDecoder().decode(
            Playlist.self,
            from: JSONEncoder().encode(playlist)
        )

        XCTAssertEqual(restored, playlist)
        XCTAssertEqual(restored.playlistID, 17)
        XCTAssertEqual(restored.id, "-42_17")
    }
}
