import XCTest
@testable import PrivateMusic

final class VKMusicServiceTests: XCTestCase {
    private func makeService() -> VKMusicService {
        VKMusicService(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!
            ),
            apiVersion: "5.131"
        )
    }

    // Defect 15: a page with fewer items than requested (e.g. 50 of 100 for
    // a 1000-track playlist) must still advance the offset, otherwise large
    // playlists silently truncate.
    func testPageContinuesWhenServerReturnsFewerItemsThanRequested() {
        let service = makeService()
        let items = (0..<50).map { $0 }

        let page = service.page(
            VKItems(count: 1000, items: items),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.nextOffset, 50)
        XCTAssertEqual(page.totalCount, 1000)
        XCTAssertEqual(page.items.count, 50)
    }

    func testPageAdvancesByExactItemCountOnFullPage() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 1000, items: Array(0..<100)),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.nextOffset, 100)
        XCTAssertEqual(page.totalCount, 1000)
    }

    func testPageStopsAfterLastPartialPage() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 1000, items: Array(0..<50)),
            offset: 950,
            requested: 100
        )

        XCTAssertNil(page.nextOffset)
    }

    func testPageHandlesEmptyResponse() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 0, items: [Int]()),
            offset: 0,
            requested: 100
        )

        XCTAssertNil(page.nextOffset)
        XCTAssertEqual(page.totalCount, 0)
    }

    func testPageFallsBackToItemCountWhenTotalMissing() {
        let service = makeService()
        let page = service.page(
            VKItems(count: nil, items: Array(0..<3)),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertNil(page.nextOffset)
    }

    func testAlbumExecuteRequestUsesPlaylistPagingContract() {
        let album = Album(
            id: 24,
            ownerID: -5,
            title: "Album",
            count: 120,
            accessKey: " secret "
        )

        let parameters = AlbumTrackRequestPolicy.executeParameters(
            album: album,
            offset: 40,
            count: 20
        )

        XCTAssertEqual(parameters["owner_id"], "-5")
        XCTAssertEqual(parameters["id"], "24")
        XCTAssertEqual(parameters["audio_offset"], "40")
        XCTAssertEqual(parameters["audio_count"], "20")
        XCTAssertEqual(parameters["access_key"], "secret")
        XCTAssertNil(parameters["album_id"])
    }

    func testAlbumLegacyRequestKeepsAudioGetContract() {
        let album = Album(
            id: 24,
            ownerID: -5,
            title: "Album",
            count: 120,
            accessKey: " "
        )

        let parameters = AlbumTrackRequestPolicy.legacyParameters(
            album: album,
            offset: 40,
            count: 20
        )

        XCTAssertEqual(parameters["owner_id"], "-5")
        XCTAssertEqual(parameters["album_id"], "24")
        XCTAssertEqual(parameters["offset"], "40")
        XCTAssertEqual(parameters["count"], "20")
        XCTAssertNil(parameters["id"])
        XCTAssertNil(parameters["access_key"])
    }

    func testExecutePlaylistResponseExtractsValidAlbumTracksLossily() throws {
        let data = """
        {
          "response": {
            "audios": [
              {
                "id": 1,
                "owner_id": -5,
                "title": "One",
                "artist": "Artist",
                "duration": 120
              },
              {"type": "ad"},
              {
                "id": 2,
                "owner_id": -5,
                "title": "Two",
                "artist": "Artist",
                "duration": 140
              }
            ],
            "playlist": {"id": 24, "owner_id": -5, "title": "Album"}
          }
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: data
        )

        XCTAssertEqual(value.tracks.map(\.trackID), [1, 2])
    }
}
