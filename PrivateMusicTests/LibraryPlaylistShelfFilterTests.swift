import XCTest
@testable import PrivateMusic

/// «ОНИ НЕ ВСЕ»: eight playlists in Медиатека and a single card on the
/// shelf.
///
/// `audio.getPlaylists` takes a comma-separated `filters` of `all`
/// (default), `owned`, `followed` and `albums`, and it *unions* the
/// categories it names. The Albums shelf asked for `followed,albums`, so VK
/// answered with every playlist saved from another person on top of the
/// releases — and since the playlist shelf subtracted every id the Albums
/// shelf reported, each of those playlists was taken off Медиатека. What is
/// left is the playlists you made yourself, which for the reporter was one.
///
/// No per-entry test could have saved them: VK sends a saved playlist with
/// nothing on it that says "playlist", so the three releases that narrowed
/// the shape test one marker at a time all left the shelf at one card.
///
/// Narrowing the request to `filters=albums` only helps while VK honours
/// it. The subtraction itself is gone now, so the playlist shelf is the
/// same eight cards whatever the Albums shelf asks for or gets back.
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
    private func shelf() throws -> [Playlist] {
        let service = makeService()
        return LibraryPlaylistShelfPolicy.normalized(
            service.playlistPage(
                try FakeVK.response(filters: nil),
                offset: 0
            ).items,
            ownerID: FakeVK.ownerID
        )
    }

    /// What the Albums shelf reports for a given `filters`, which used to be
    /// subtracted from the shelf above.
    private func albumShelfIdentities(
        filters: String
    ) throws -> Set<String> {
        Set(
            makeService()
                .followedAlbumPage(
                    try FakeVK.response(filters: filters),
                    offset: 0
                )
                .items
                .map(\.compositeID)
        )
    }

    // The defect, reproduced end to end: the Albums shelf reports all seven
    // saved playlists as releases, and the shelf used to subtract exactly
    // that — which is how the reporter was left with one card.
    func testTheOldUnionFilterStillReportsEverySavedPlaylistAsAnAlbum()
        throws {
        let identities = try albumShelfIdentities(filters: "followed,albums")

        XCTAssertEqual(identities.count, 10)
        XCTAssertEqual(
            try shelf()
                .filter { $0.title.hasPrefix("Сохранённый") }
                .filter { identities.contains($0.libraryIdentity) }
                .count,
            7
        )
    }

    // The fix: the shelf keeps them anyway, because it subtracts nothing.
    func testEveryPlaylistReachesTheShelf() throws {
        let shelf = try shelf()

        XCTAssertEqual(
            shelf.filter { $0.title.hasPrefix("Release") == false }
                .map(\.title),
            ["Дорога"] + (1...7).map { "Сохранённый \($0)" }
        )
    }

    // The cost of dropping the subtraction, stated outright: a release VK
    // sent with no marker at all now rides along on Медиатека. A release
    // that slips through still renders a card that opens and plays, and a
    // playlist that is subtracted is simply gone — which is the defect.
    func testAnUnmarkedReleaseRidesAlongRatherThanCostingAPlaylist() throws {
        let shelf = try shelf()

        XCTAssertEqual(
            shelf.filter { $0.title.hasPrefix("Release") }.map(\.title),
            ["Release 3"],
            "the releases VK typed are still filtered by album_type"
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
