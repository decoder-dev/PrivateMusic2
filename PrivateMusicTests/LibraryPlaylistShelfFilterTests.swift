import XCTest
@testable import PrivateMusic

/// «ОНИ НЕ ВСЕ», the fourth time round: eight playlists in Медиатека and a
/// single card on the shelf, still there after 3.28.68.
///
/// `audio.getPlaylists` takes a comma-separated `filters` of `all` (default),
/// `owned`, `followed` and `albums`, and it *unions* the categories it names.
/// The Albums shelf asked for `followed,albums`, so VK answered with every
/// playlist saved from another person on top of the releases — and since the
/// playlist shelf subtracts every id the Albums shelf reports, each of those
/// playlists was taken off Медиатека. What is left is the playlists you made
/// yourself, which for the reporter was one.
///
/// No per-entry test could have saved them: VK sends a saved playlist with
/// nothing on it that says "playlist", so the three releases that narrowed
/// the shape test one marker at a time all left the shelf at one card.
final class LibraryPlaylistShelfFilterTests: XCTestCase {
    /// `audio.getPlaylists` with the `filters` semantics VK documents.
    private struct FakeVK {
        static let ownerID = 555

        /// The one playlist the reporter made themselves.
        static let owned = """
        {
          "id": 101, "owner_id": \(ownerID), "type": 0, "title": "Дорога",
          "count": 12, "followers": 0, "plays": 3, "is_following": false,
          "access_key": "own"
        }
        """

        /// Seven playlists saved from other people. VK marks none of them:
        /// no `album_type`, no `original` pointer.
        static let followedPlaylists: [String] = (1...7).map { index in
            """
            {
              "id": \(200 + index), "owner_id": \(900 + index), "type": 0,
              "title": "Сохранённый \(index)", "count": \(10 * index),
              "followers": 12, "plays": 900, "is_following": true,
              "access_key": "saved\(index)"
            }
            """
        }

        static let albums: [String] = (1...2).map { index in
            """
            {
              "id": \(300 + index), "owner_id": \(-2_000_000 - index),
              "type": 1, "title": "Release \(index)", "count": 10,
              "main_artists": [{"name": "Artist \(index)"}], "year": 2021,
              "album_type": "main_only", "is_following": true,
              "access_key": "album\(index)"
            }
            """
        } + [
            // A release VK sent with nothing on it. The shape test leaves it
            // alone by design, so only the ids the Albums shelf reports can
            // keep it off the playlist shelf.
            """
            {
              "id": 303, "owner_id": -2000003, "title": "Release 3",
              "count": 10, "access_key": "album3"
            }
            """
        ]

        static func response(filters: String?) throws -> JSONValue {
            let requested = Set(
                (filters ?? "all")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            )
            func wants(_ category: String) -> Bool {
                requested.contains("all") || requested.contains(category)
            }
            var entries: [String] = []
            if wants("owned") { entries.append(owned) }
            if wants("followed") {
                entries.append(contentsOf: followedPlaylists)
            }
            if wants("albums") { entries.append(contentsOf: albums) }
            let json = """
            {
              "count": \(entries.count),
              "items": [\(entries.joined(separator: ","))]
            }
            """
            return try JSONDecoder().decode(
                JSONValue.self,
                from: Data(json.utf8)
            )
        }
    }

    private func makeService() -> VKMusicService {
        VKMusicService(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!
            ),
            apiVersion: "5.131"
        )
    }

    /// The whole library shelf, assembled the way the app assembles it.
    private func shelf(albumShelfFilters: String) throws -> [Playlist] {
        let service = makeService()
        let identities = Set(
            service.followedAlbumPage(
                try FakeVK.response(filters: albumShelfFilters),
                offset: 0
            )
            .items
            .map(\.compositeID)
        )
        return LibraryPlaylistShelfPolicy.normalized(
            service.playlistPage(
                try FakeVK.response(filters: nil),
                offset: 0
            ).items,
            ownerID: FakeVK.ownerID,
            followedAlbumIdentities: identities
        )
    }

    // The defect, reproduced end to end.
    func testTheOldUnionFilterHidesSevenOfEightPlaylists() throws {
        XCTAssertEqual(try shelf(albumShelfFilters: "followed,albums").count, 1)
    }

    // The fix: every playlist reaches the shelf, and no release does.
    func testEveryPlaylistReachesTheShelf() throws {
        let shelf = try shelf(
            albumShelfFilters: LibraryPlaylistPagePolicy.albumShelfFilters
        )

        XCTAssertEqual(shelf.count, 8)
        XCTAssertEqual(shelf.first?.title, "Дорога")
        XCTAssertEqual(
            shelf.dropFirst().map(\.title),
            (1...7).map { "Сохранённый \($0)" }
        )
        XCTAssertFalse(
            shelf.contains { $0.title.hasPrefix("Release") },
            "followed releases stay on the Albums shelf"
        )
    }

    // The Albums shelf must not lose anything to the narrower request.
    func testTheAlbumsShelfStillGetsEveryRelease() throws {
        let page = makeService().followedAlbumPage(
            try FakeVK.response(
                filters: LibraryPlaylistPagePolicy.albumShelfFilters
            ),
            offset: 0
        )

        XCTAssertEqual(page.items.map(\.albumID), [301, 302, 303])
    }

    func testTheAlbumShelfRequestAsksForReleasesAlone() {
        XCTAssertEqual(LibraryPlaylistPagePolicy.albumShelfFilters, "albums")
        XCTAssertFalse(
            LibraryPlaylistPagePolicy.albumShelfFilters.contains("followed"),
            "`filters` unions its categories: `followed` adds saved playlists"
        )
    }
}
