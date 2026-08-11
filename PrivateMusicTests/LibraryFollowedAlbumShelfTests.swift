import XCTest
@testable import PrivateMusic

/// The Albums shelf loads `audio.getPlaylists` with `filters=albums` and
/// classifies the answer entry by entry.
///
/// It used to hand its ids to the playlist shelf, which subtracted them.
/// That coupling is gone: whatever this shelf gets wrong now costs an album
/// card and nothing else, because no list it produces can take a playlist
/// off Медиатека.
final class LibraryFollowedAlbumShelfTests: XCTestCase {
    private func makeService() -> VKMusicService {
        VKMusicService(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!
            ),
            apiVersion: "5.131"
        )
    }

    private func payload(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testSavedPlaylistsStayOffTheAlbumsShelfList() throws {
        let value = try payload(
            """
            {
              "count": 4,
              "items": [
                {
                  "id": 10,
                  "owner_id": -5,
                  "title": "Release",
                  "album_type": "album",
                  "type": 1,
                  "year": 2019,
                  "main_artists": [{"name": "Artist"}]
                },
                {
                  "id": 11,
                  "owner_id": 300,
                  "title": "Сборник друга",
                  "type": 1,
                  "year": 2020,
                  "main_artists": [{"name": "Artist"}],
                  "original": {"playlist_id": 9, "owner_id": 300}
                },
                {
                  "id": 12,
                  "owner_id": 400,
                  "title": "Чужой плейлист",
                  "album_type": "playlist"
                },
                {
                  "id": 13,
                  "owner_id": 500,
                  "title": "Подборка",
                  "album_type": "collection"
                }
              ]
            }
            """
        )

        let page = makeService().followedAlbumPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.albumID), [10])
    }

    // Nothing that is really a release may be lost here either, or the
    // Albums shelf itself comes back short.
    func testEveryReleaseShapeStaysOnTheAlbumsShelfList() throws {
        let value = try payload(
            """
            {
              "count": 3,
              "items": [
                {"id": 1, "owner_id": -5, "title": "Без типа"},
                {
                  "id": 2,
                  "owner_id": -6,
                  "title": "Studio",
                  "album_type": "main_only",
                  "main_artists": [{"name": "Artist"}]
                },
                {
                  "id": 3,
                  "owner_id": -7,
                  "title": "Single",
                  "album_type": "single",
                  "type": 1
                }
              ]
            }
            """
        )

        let page = makeService().followedAlbumPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.albumID), [1, 2, 3])
    }

    // Advancing by the number of decoded albums would re-request a window
    // full of saved playlists forever.
    func testOffsetAdvancesByRawEntriesNotByDecodedAlbums() throws {
        let value = try payload(
            """
            {
              "count": 250,
              "items": [
                {"id": 1, "owner_id": -5, "title": "Release"},
                {
                  "id": 2,
                  "owner_id": 300,
                  "title": "Сохранённый",
                  "original": {"playlist_id": 2, "owner_id": 300}
                },
                {"id": 3, "owner_id": 400, "title": "Плейлист", "album_type": "playlist"}
              ]
            }
            """
        )

        let page = makeService().followedAlbumPage(value, offset: 100)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextOffset, 103)
    }

    func testEmptyFollowedPageStopsPaging() throws {
        let value = try payload("{\"count\": 120, \"items\": []}")

        let page = makeService().followedAlbumPage(value, offset: 120)

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextOffset)
    }

    // The reported defect, in the shape it reached users: eight playlists in
    // Медиатека, seven of them saved from other people, and a single card on
    // the shelf. Every one of these eight also decodes as an `Album`, which
    // is exactly what the identity subtraction used to act on.
    func testEverySavedPlaylistStaysOnTheLibraryShelf() throws {
        let saved = (2...8).map { index in
            """
            {
              "id": \(index),
              "owner_id": \(300 + index),
              "title": "Сохранённый \(index)",
              "type": 1,
              "year": 2019,
              "main_artists": [{"name": "Artist"}]
            }
            """
        }
        let owned = """
        {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12}
        """
        let service = makeService()

        // The worst case the Albums shelf can produce: it read every one of
        // the eight playlists as a release.
        let followed = try payload(
            """
            {
              "count": \(saved.count + 1),
              "items": [\(([owned] + saved).joined(separator: ","))]
            }
            """
        )
        XCTAssertEqual(
            service.followedAlbumPage(followed, offset: 0).items.count,
            8,
            "the Albums shelf list is what the shelf used to subtract"
        )

        let library = try payload(
            """
            {
              "count": \(saved.count + 1),
              "items": [\(([owned] + saved).joined(separator: ","))]
            }
            """
        )
        let shelf = LibraryPlaylistShelfPolicy.normalized(
            service.playlistPage(library, offset: 0).items,
            ownerID: 100
        )

        XCTAssertEqual(shelf.count, 8)
        XCTAssertEqual(shelf.first?.title, "Дорога")
        XCTAssertEqual(
            shelf.dropFirst().map(\.title),
            (2...8).map { "Сохранённый \($0)" }
        )
    }

    // The shelf has no way to be handed an exclusion set any more. Keeping
    // the parameter around is what let one call site quietly go on
    // subtracting after the rest of the app had stopped.
    func testTheShelfPolicyTakesNoAlbumExclusionSet() {
        let mine = Playlist(id: 7, ownerID: 100, title: "Дорога", count: 12)
        let theirs = Playlist(id: 7, ownerID: -5, title: "Сборник", count: 9)

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [mine, theirs],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.libraryIdentity), ["100_7", "-5_7"])
    }

    // The session can be restored before the profile lands, and then the
    // shelf does not know whose playlists these are. It must still show all
    // of them: an unknown owner used to disable the one guard that kept the
    // subtraction off your own playlists.
    func testAnUnknownOwnerStillKeepsEveryPlaylist() {
        let playlists = (1...8).map {
            Playlist(id: $0, ownerID: 100, title: "P\($0)", count: $0)
        }

        let shelf = LibraryPlaylistShelfPolicy.normalized(playlists)

        XCTAssertEqual(shelf.count, 8)
    }
}

final class LibraryAlbumsShelfEntryPolicyTests: XCTestCase {
    func testPlaylistMarkedEntriesNeverCountAsFollowedAlbums() {
        let playlistShaped: [LibraryPlaylistEntry] = [
            LibraryPlaylistEntry(hasOriginalPlaylist: true),
            LibraryPlaylistEntry(albumType: "playlist"),
            LibraryPlaylistEntry(albumType: "COLLECTION"),
            LibraryPlaylistEntry(
                albumType: "album",
                hasMainArtists: true,
                hasReleaseYear: true,
                vkType: 1,
                hasOriginalPlaylist: true
            )
        ]

        for entry in playlistShaped {
            XCTAssertFalse(
                LibraryPlaylistEntryPolicy.belongsOnAlbumsShelf(entry),
                "\(entry) is a playlist wherever VK returns it"
            )
        }
    }

    // The Albums shelf keeps everything the playlist test is unsure about:
    // the two shelves must partition the list, not both drop an entry.
    func testAmbiguousEntriesStillCountAsFollowedAlbums() {
        let ambiguous: [LibraryPlaylistEntry] = [
            LibraryPlaylistEntry(),
            LibraryPlaylistEntry(vkType: 1),
            LibraryPlaylistEntry(albumType: "single"),
            LibraryPlaylistEntry(hasMainArtists: true, hasReleaseYear: true)
        ]

        for entry in ambiguous {
            XCTAssertTrue(
                LibraryPlaylistEntryPolicy.belongsOnAlbumsShelf(entry),
                "\(entry) carries no playlist marker"
            )
        }
    }
}
