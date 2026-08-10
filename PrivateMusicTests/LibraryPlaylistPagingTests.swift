import XCTest
@testable import PrivateMusic

final class LibraryPlaylistPagingTests: XCTestCase {
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

    // The reported defect: one undecodable entry used to fail the whole
    // `audio.getPlaylists` page, hiding every playlist behind it.
    func testUndecodableEntryDoesNotHideTheRestOfThePage() throws {
        let value = try payload(
            """
            {
              "count": 3,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12},
                {"type": "ad"},
                {"id": 2, "owner_id": 100, "title": "Джаз", "count": 4}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.title), ["Дорога", "Джаз"])
    }

    func testEntriesWithoutATitleAreSkippedInsteadOfFailingThePage() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {"id": 1, "owner_id": 100},
                {"id": 2, "owner_id": 100, "title": "Джаз"}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [2])
    }

    func testFollowedAlbumsStayOffThePlaylistShelf() throws {
        let value = try payload(
            """
            {
              "count": 4,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12},
                {
                  "id": 2,
                  "owner_id": -5,
                  "title": "Release",
                  "type": 1,
                  "year": 2019,
                  "main_artists": [{"name": "Artist"}],
                  "count": 10
                },
                {
                  "id": 3,
                  "owner_id": -6,
                  "title": "Signed",
                  "main_artists": [{"name": "Artist"}],
                  "album_type": "main_only",
                  "count": 9
                },
                {
                  "id": 4,
                  "owner_id": -7,
                  "title": "Single",
                  "album_type": "single",
                  "type": 1,
                  "count": 1
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1])
    }

    // The reported defect: the shelf showed one playlist out of eight. Any
    // one of these markers on its own used to delete a real playlist, and VK
    // stamps them on ordinary playlists all the time.
    func testASingleAmbiguousMarkerNeverDropsAPlaylist() throws {
        let value = try payload(
            """
            {
              "count": 4,
              "items": [
                {
                  "id": 1,
                  "owner_id": 100,
                  "title": "Сохранённый плейлист",
                  "type": 1,
                  "count": 12
                },
                {
                  "id": 2,
                  "owner_id": 100,
                  "title": "С артиста",
                  "main_artists": [{"name": "Artist"}],
                  "count": 30
                },
                {
                  "id": 3,
                  "owner_id": 100,
                  "title": "Итоги 2019",
                  "year": 2019,
                  "count": 40
                },
                {
                  "id": 4,
                  "owner_id": 100,
                  "title": "Сингловый вечер",
                  "album_type": "single",
                  "count": 7
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2, 3, 4])
    }

    func testPlaylistTypedEntriesAreNeverMistakenForAlbums() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {
                  "id": 1,
                  "owner_id": 100,
                  "title": "Дорога",
                  "type": 0,
                  "album_type": "playlist",
                  "main_artists": [],
                  "count": 12
                },
                {
                  "id": 2,
                  "owner_id": 300,
                  "title": "Сборник друга",
                  "original": {"playlist_id": 9, "owner_id": 300},
                  "count": 3
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2])
    }

    // A playlist saved from another owner carries `original`, and VK types
    // some of them as `1`. It is still a playlist.
    func testASavedPlaylistSurvivesEveryReleaseMarker() throws {
        let value = try payload(
            """
            {
              "count": 1,
              "items": [
                {
                  "id": 7,
                  "owner_id": 300,
                  "title": "Сборник друга",
                  "type": 1,
                  "year": 2020,
                  "main_artists": [{"name": "Artist"}],
                  "original": {"playlist_id": 9, "owner_id": 300},
                  "count": 3
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [7])
    }

    // Advancing by the number of decoded playlists would re-request this
    // window forever whenever VK filled a page with followed albums.
    func testOffsetAdvancesByRawEntriesNotByDecodedPlaylists() throws {
        let value = try payload(
            """
            {
              "count": 250,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12},
                {
                  "id": 2,
                  "owner_id": -5,
                  "title": "A",
                  "type": 1,
                  "year": 2021,
                  "main_artists": [{"name": "Artist"}]
                },
                {
                  "id": 3,
                  "owner_id": -6,
                  "title": "B",
                  "type": 1,
                  "year": 2022,
                  "main_artists": [{"name": "Artist"}]
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 100)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.totalCount, 250)
        XCTAssertEqual(page.nextOffset, 103)
    }

    func testPagingStopsOnTheLastPage() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12},
                {"id": 2, "owner_id": 100, "title": "Джаз", "count": 4}
              ]
            }
            """
        )

        XCTAssertNil(makeService().playlistPage(value, offset: 0).nextOffset)
    }

    func testEmptyPageStopsPaging() throws {
        let value = try payload("{\"count\": 120, \"items\": []}")

        let page = makeService().playlistPage(value, offset: 120)

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextOffset)
    }

    func testPrefetchCoversLibrariesFullOfFollowedAlbums() {
        XCTAssertEqual(LibraryPlaylistPagePolicy.pageSize, 100)
        XCTAssertGreaterThanOrEqual(
            LibraryPlaylistPagePolicy.prefetchPages,
            3,
            "one page can decode into a handful of playlists"
        )
        XCTAssertGreaterThanOrEqual(
            LibraryPlaylistPagePolicy.prefetchCapacity,
            300
        )
    }
}

@MainActor
final class PlaylistLibraryViewModelTests: XCTestCase {
    private final class OffsetRecorder {
        var offsets: [Int] = []
    }

    func testInitialLoadWalksSeveralPages() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)
        let recorder = OffsetRecorder()

        await model.load(pages: 5) { offset in
            recorder.offsets.append(offset)
            let index = offset / 2
            return MusicPage(
                items: [
                    makePlaylist(id: index * 2 + 1, title: "A\(offset)"),
                    makePlaylist(id: index * 2 + 2, title: "B\(offset)")
                ],
                totalCount: 6,
                nextOffset: offset + 2 < 6 ? offset + 2 : nil
            )
        }

        XCTAssertEqual(recorder.offsets, [0, 2, 4])
        XCTAssertEqual(model.playlists.count, 6)
    }

    func testInitialLoadStopsAtThePrefetchCapAndKeepsPaginating() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load(pages: 2) { offset in
            MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 100,
                nextOffset: offset + 1
            )
        }
        XCTAssertEqual(model.playlists.count, 2)

        await model.loadMore { offset in
            XCTAssertEqual(offset, 2)
            return MusicPage(
                items: [makePlaylist(id: 3, title: "P2")],
                totalCount: 100,
                nextOffset: 3
            )
        }

        XCTAssertEqual(model.playlists.count, 3)
    }

    func testAFailedLaterPageKeepsThePlaylistsThatLoaded() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load(pages: 3) { offset in
            guard offset == 0 else { throw URLError(.timedOut) }
            return MusicPage(
                items: [makePlaylist(id: 1, title: "Дорога")],
                totalCount: 50,
                nextOffset: 1
            )
        }

        XCTAssertEqual(model.playlists.count, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testFirstPageFailureSurfacesTheError() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load { _ in throw URLError(.timedOut) }

        XCTAssertTrue(model.playlists.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    // The library task is cancelled on every tab switch and token change. A
    // prefetch cut short there used to count as done, so the shelf stayed on
    // whichever page happened to land first.
    func testACancelledPrefetchIsResumedByTheNextLoad() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load(pages: 5) { offset in
            guard offset == 0 else { throw CancellationError() }
            return MusicPage(
                items: [makePlaylist(id: 1, title: "Дорога")],
                totalCount: 8,
                nextOffset: 1
            )
        }
        XCTAssertEqual(model.playlists.count, 1)

        await model.load(pages: 5) { offset in
            MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 8,
                nextOffset: offset + 1 < 8 ? offset + 1 : nil
            )
        }

        XCTAssertEqual(model.playlists.count, 5)
    }

    func testACompletedPrefetchIsNotRepeated() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)
        let recorder = OffsetRecorder()

        for _ in 0..<3 {
            await model.load { offset in
                recorder.offsets.append(offset)
                return MusicPage(
                    items: [makePlaylist(id: 1, title: "Дорога")],
                    totalCount: 1,
                    nextOffset: nil
                )
            }
        }

        XCTAssertEqual(recorder.offsets, [0])
    }

    // Albums ride along in the unfiltered playlist list. The Albums shelf
    // knows their exact ids, so the playlist shelf drops them by id rather
    // than guessing from the shape of the entry.
    func testFollowedAlbumIdentitiesAreDroppedFromTheShelf() async {
        let model = PlaylistLibraryViewModel()
        model.configure(
            ownerID: 100,
            followedAlbumIdentities: ["-5_2"]
        )

        await model.load { _ in
            MusicPage(
                items: [
                    makePlaylist(id: 1, title: "Дорога"),
                    Playlist(id: 2, ownerID: -5, title: "Release", count: 10),
                    makePlaylist(id: 3, title: "Джаз")
                ],
                totalCount: 3,
                nextOffset: nil
            )
        }

        XCTAssertEqual(model.playlists.map(\.title), ["Дорога", "Джаз"])
    }

    func testAlbumsThatLandAfterThePrefetchAreFilteredWithoutARefetch() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load { _ in
            MusicPage(
                items: [
                    makePlaylist(id: 1, title: "Дорога"),
                    Playlist(id: 2, ownerID: -5, title: "Release", count: 10)
                ],
                totalCount: 2,
                nextOffset: nil
            )
        }
        XCTAssertEqual(model.playlists.count, 2)

        model.excludeFollowedAlbums(["-5_2"])

        XCTAssertEqual(model.playlists.map(\.title), ["Дорога"])
    }

    private func makePlaylist(id: Int, title: String) -> Playlist {
        Playlist(id: id, ownerID: 100, title: title, count: 3)
    }
}
