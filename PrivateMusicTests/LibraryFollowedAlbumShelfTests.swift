import XCTest
@testable import PrivateMusic

/// The Albums shelf loads `audio.getPlaylists` with
/// `filters=followed,albums`, and the playlist shelf subtracts every id that
/// list reports. `followed` is not an album filter — VK answers it with the
/// playlists saved from other people too — so anything left in that list
/// disappears from Медиатека.
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

    // Nothing that is really a release may be lost here either: the playlist
    // shelf drops followed albums by exactly these ids, so an album missing
    // from this list floods Медиатека instead.
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
    // the shelf. The identity subtraction was fed the followed list verbatim,
    // so every saved playlist in it was taken for a release.
    func testEverySavedPlaylistStaysOnTheLibraryShelf() throws {
        let saved = (2...8).map { index in
            """
            {
              "id": \(index),
              "owner_id": \(300 + index),
              "title": "Сохранённый \(index)",
              "type": 1,
              "year": 2019,
              "main_artists": [{"name": "Artist"}],
              "original": {"playlist_id": \(index), "owner_id": \(300 + index)}
            }
            """
        }
        // A release VK sent without a single marker on it: the shape test
        // leaves it alone by design, so only the identity subtraction can
        // keep it off the playlist shelf.
        let release = """
        {"id": 90, "owner_id": -5, "title": "Release", "count": 9}
        """
        let owned = """
        {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12}
        """
        let service = makeService()

        let followed = try payload(
            """
            {
              "count": \(saved.count + 1),
              "items": [\((saved + [release]).joined(separator: ","))]
            }
            """
        )
        let identities = Set(
            service.followedAlbumPage(followed, offset: 0)
                .items
                .map(\.compositeID)
        )
        XCTAssertEqual(identities, ["-5_90"])

        let library = try payload(
            """
            {
              "count": \(saved.count + 2),
              "items": [\(([owned] + saved + [release]).joined(separator: ","))]
            }
            """
        )
        let shelf = LibraryPlaylistShelfPolicy.normalized(
            service.playlistPage(library, offset: 0).items,
            ownerID: 100,
            followedAlbumIdentities: identities
        )

        XCTAssertEqual(shelf.count, 8)
        XCTAssertEqual(shelf.first?.title, "Дорога")
        XCTAssertFalse(
            shelf.contains { $0.libraryIdentity == "-5_90" },
            "the followed release still belongs to the Albums shelf"
        )
    }

    // A release cannot belong to a person, so an id that matches the Albums
    // shelf while it is one of your own playlists is a fault in that shelf.
    func testAnOwnedPlaylistSurvivesAnAlbumIdentityCollision() {
        let mine = Playlist(id: 7, ownerID: 100, title: "Дорога", count: 12)
        let theirs = Playlist(id: 7, ownerID: -5, title: "Release", count: 9)

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [mine, theirs],
            ownerID: 100,
            followedAlbumIdentities: ["100_7", "-5_7"]
        )

        XCTAssertEqual(shelf.map(\.libraryIdentity), ["100_7"])
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
