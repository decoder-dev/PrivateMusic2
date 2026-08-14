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

    // An entry VK sent without a title used to be dropped outright. A card
    // with no caption is still a playlist you can open; an absent card is
    // one more «они не все».
    func testAnEntryWithoutATitleStaysOnTheShelf() throws {
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

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2])
        XCTAssertEqual(page.items.first?.title, L10n.text("playlist"))
    }

    // Only an entry with no owner-scoped id at all is unusable.
    func testAnEntryWithoutAnIdIsSkippedInsteadOfFailingThePage() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {"title": "Без идентификатора"},
                {"id": 2, "owner_id": 100, "title": "Джаз"}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [2])
    }

    // VK is not consistent about number vs string ids, and a strict `Int`
    // decode threw the entry away.
    func testStringEncodedIdentifiersStillDecode() throws {
        let value = try payload(
            """
            {
              "count": 1,
              "items": [
                {"id": "42", "owner_id": "-7", "title": "Дорога", "count": "12"}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.libraryIdentity), ["-7_42"])
        XCTAssertEqual(page.items.first?.count, 12)
    }

    // Only an entry VK typed as a release, named the artists behind and
    // dated is dropped here. «Signed» carries the type and the artists but
    // no year, «Single» the type and `type: 1` but no artists — and
    // `type: 1` is what a playlist saved from another owner reports too, so
    // both keep their card. Both still reach the Albums shelf.
    func testUnmistakableReleasesStayOffThePlaylistShelf() throws {
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
                  "album_type": "album",
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

        let service = makeService()

        XCTAssertEqual(
            service.playlistPage(value, offset: 0).items.map(\.playlistID),
            [1, 3, 4]
        )
        let albumShelf = service.followedAlbumPage(value, offset: 0)
            .items
            .map(\.albumID)
        for release in [2, 3, 4] {
            XCTAssertTrue(
                albumShelf.contains(release),
                "a release kept on the playlist shelf is still an album"
            )
        }
    }

    // The reported defect, third time round: «ОНИ НЕ ВСЕ». Every entry here
    // carries two of the markers the old heuristic counted, so it kept
    // exactly one of the eight playlists. None of those markers is a
    // release type, so all eight must survive.
    func testAmbiguousMarkerPairsNeverDropPlaylists() throws {
        let value = try payload(
            """
            {
              "count": 8,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12},
                {
                  "id": 2,
                  "owner_id": 100,
                  "title": "Сохранённый 2019",
                  "type": 1,
                  "year": 2019,
                  "count": 30
                },
                {
                  "id": 3,
                  "owner_id": 100,
                  "title": "С артиста",
                  "type": 1,
                  "main_artists": [{"name": "Artist"}],
                  "count": 24
                },
                {
                  "id": 4,
                  "owner_id": 100,
                  "title": "Итоги года",
                  "year": 2021,
                  "main_artists": [{"name": "Artist"}],
                  "count": 40
                },
                {
                  "id": 5,
                  "owner_id": 100,
                  "title": "Все маркеры сразу",
                  "type": 1,
                  "year": 2020,
                  "main_artists": [{"name": "Artist"}],
                  "count": 18
                },
                {
                  "id": 6,
                  "owner_id": 100,
                  "title": "Старое",
                  "type": 1,
                  "original_year": 1998,
                  "count": 7
                },
                {
                  "id": 7,
                  "owner_id": 100,
                  "title": "Сборник",
                  "original_year": 2005,
                  "main_artists": [{"name": "Artist"}],
                  "count": 11
                },
                {
                  "id": 8,
                  "owner_id": 100,
                  "title": "Дубль",
                  "type": 1,
                  "year": 2015,
                  "main_artists": [
                    {"name": "Artist"},
                    {"name": "Feature"}
                  ],
                  "count": 9
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(
            page.items.map(\.playlistID),
            [1, 2, 3, 4, 5, 6, 7, 8]
        )
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
                  "album_type": "album",
                  "main_artists": [{"name": "Artist"}]
                },
                {
                  "id": 3,
                  "owner_id": -6,
                  "title": "B",
                  "type": 1,
                  "year": 2022,
                  "album_type": "album",
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

    // VK's `count` for the unfiltered list does not always describe the same
    // set as `items`. Trusting it alone stopped the walk on the first page
    // and hid every playlist behind it.
    func testAFullPageContinuesEvenWhenTheTotalUnderreports() throws {
        let entries = (1...4).map {
            "{\"id\": \($0), \"owner_id\": 100, \"title\": \"P\($0)\"}"
        }
        let value = try payload(
            "{\"count\": 2, \"items\": [\(entries.joined(separator: ","))]}"
        )

        let page = makeService().playlistPage(value, offset: 0, requested: 4)

        XCTAssertEqual(page.items.count, 4)
        XCTAssertEqual(page.nextOffset, 4)
        XCTAssertEqual(page.totalCount, 4)
    }

    // A short page still continues while VK says there is more, so a
    // trimmed window cannot end the walk early either.
    func testAShortPageStillContinuesWhileTheTotalPromisesMore() throws {
        let value = try payload(
            """
            {
              "count": 900,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога", "count": 12}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0, requested: 100)

        XCTAssertEqual(page.nextOffset, 1)
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

    // Reading only the one block the app expected left the shelf with
    // whichever handful of entries happened to be there.
    func testAPageDeliveredUnderAPlaylistsBlockIsStillRead() throws {
        let value = try payload(
            """
            {
              "playlists": {
                "count": 3,
                "items": [
                  {"id": 1, "owner_id": 100, "title": "Дорога"},
                  {"id": 2, "owner_id": 100, "title": "Джаз"},
                  {"id": 3, "owner_id": 100, "title": "rock"}
                ]
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2, 3])
    }

    func testEntriesWrappedInABlockAreUnwrapped() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {
                  "type": "music_playlist",
                  "playlist": {
                    "id": 1, "owner_id": 100, "title": "Дорога", "count": 12
                  }
                },
                {"id": 2, "owner_id": 100, "title": "Джаз"}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2])
    }

    // An empty top-level `items` says the window VK answered with held
    // nothing, so the walk ends here. It does not say the playlists beside
    // it are not playlists: reading it that way is what left the reporter
    // with a single card when VK answered in this shape.
    func testAnEmptyItemsStillReadsThePlaylistsBesideIt() throws {
        let value = try payload(
            """
            {
              "count": 8,
              "items": [],
              "playlists": {
                "items": [{"id": 1, "owner_id": 100, "title": "Дорога"}]
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 40)

        XCTAssertEqual(page.items.map(\.playlistID), [1])
        XCTAssertNil(
            page.nextOffset,
            "an empty window ends the walk however many siblings it has"
        )
    }

    // The walk must still terminate: a payload that answers every offset
    // with the same sibling block would otherwise be requested forever.
    func testAnEmptyItemsEndsTheWalkOnEveryPage() throws {
        let value = try payload(
            """
            {
              "count": 900,
              "items": [],
              "sections": [
                {
                  "items": [
                    {"playlist": {"id": 1, "owner_id": 100, "title": "rock"}}
                  ]
                }
              ]
            }
            """
        )

        for offset in [0, 100, 800] {
            let page = makeService().playlistPage(value, offset: offset)

            XCTAssertEqual(page.items.map(\.playlistID), [1])
            XCTAssertNil(page.nextOffset)
        }
    }

    // The whole page under a sibling block, arriving on the first request
    // with `items` left empty — the shape the shelf used to read as an
    // empty library.
    func testAFirstPageCarriedEntirelyByASiblingBlockReachesTheShelf()
        throws {
        let value = try payload(
            """
            {
              "count": 8,
              "items": [],
              "playlists": [
                {"id": 1, "owner_id": 100, "title": "Мне нравится"},
                {"id": 2, "owner_id": 100, "title": "Мне нравится (2)"},
                {"id": 3, "owner_id": 100, "title": "Дорога"},
                {"id": 4, "owner_id": 900, "title": "Сохранённый"}
              ]
            }
            """
        )

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            makeService().playlistPage(value, offset: 0).items,
            ownerID: 100
        )

        XCTAssertEqual(
            shelf.map(\.title),
            [
                "Мне нравится",
                "Мне нравится (2)",
                "Дорога",
                "Сохранённый"
            ]
        )
    }

    // The screenshot case. VK scattered a library of eight playlists across
    // four blocks of one payload, and a parser that stopped at the first
    // block holding anything rendered the single entry in `items` — one
    // card out of eight.
    func testEveryBlockOfAScatteredPageReachesTheShelf() throws {
        let value = try payload(
            """
            {
              "count": 8,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Мне нравится",
                 "count": 118}
              ],
              "playlists": {
                "count": 8,
                "items": [
                  {"id": 1, "owner_id": 100, "title": "Мне нравится",
                   "count": 118},
                  {"id": 2, "owner_id": 100, "title": "Дорога", "count": 12},
                  {"id": 3, "owner_id": 100, "title": "Джаз", "count": 4}
                ]
              },
              "blocks": [
                {
                  "id": "block_playlists",
                  "items": [
                    {
                      "type": "music_playlist",
                      "playlist": {
                        "id": 4, "owner_id": 100, "title": "rock", "count": 9
                      }
                    },
                    {
                      "type": "music_playlist",
                      "playlist": {
                        "id": 5,
                        "owner_id": 300,
                        "title": "Сборник друга",
                        "original": {"playlist_id": 5, "owner_id": 300}
                      }
                    }
                  ]
                }
              ],
              "response": {
                "playlists": {
                  "items": [
                    {"id": 6, "owner_id": 100, "title": "Итоги 2019",
                     "year": 2019},
                    {"id": 7, "owner_id": 100, "title": "С артиста",
                     "main_artists": [{"name": "Artist"}]},
                    {"id": 8, "owner_id": 100, "title": "Без названия"}
                  ]
                }
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(
            page.items.map(\.playlistID).sorted(),
            [1, 2, 3, 4, 5, 6, 7, 8]
        )
    }

    // The same playlist arriving under two blocks is one playlist.
    func testAPlaylistRepeatedAcrossBlocksRendersOneCard() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [{"id": 1, "owner_id": 100, "title": "Дорога"}],
              "playlists": {
                "items": [
                  {"id": 1, "owner_id": 100, "title": "Дорога"},
                  {"id": 2, "owner_id": 100, "title": "Джаз"}
                ]
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2])
    }

    // Entries merged from a sibling block are another copy of the list, not
    // a continuation of it: advancing past them would step over entries VK
    // has not sent yet.
    func testMergedSiblingEntriesDoNotMoveTheOffset() throws {
        let value = try payload(
            """
            {
              "count": 900,
              "items": [
                {"id": 1, "owner_id": 100, "title": "Дорога"},
                {"type": "ad"},
                {"id": 2, "owner_id": 100, "title": "Джаз"}
              ],
              "playlists": {
                "items": [
                  {"id": 3, "owner_id": 100, "title": "rock"},
                  {"id": 4, "owner_id": 100, "title": "Классика"}
                ]
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 100)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2, 3, 4])
        XCTAssertEqual(page.nextOffset, 103)
    }

    // A block can carry an owner-scoped id of its own. Decoding that
    // instead of the playlist it wraps produced a card that opens nothing.
    func testTheWrappedPlaylistWinsOverTheBlockAroundIt() throws {
        let value = try payload(
            """
            {
              "count": 1,
              "items": [
                {
                  "id": 999,
                  "owner_id": 100,
                  "type": "music_playlist",
                  "playlist": {
                    "id": 7, "owner_id": 100, "title": "Дорога", "count": 12
                  }
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [7])
        XCTAssertEqual(page.items.first?.title, "Дорога")
    }

    // Merging must not smuggle followed releases onto the playlist shelf.
    func testReleasesMergedFromAnAlbumsBlockStayOffTheShelf() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [{"id": 1, "owner_id": 100, "title": "Дорога"}],
              "albums": {
                "items": [
                  {
                    "id": 2,
                    "owner_id": -5,
                    "title": "Release",
                    "type": 1,
                    "year": 2020,
                    "album_type": "album",
                    "main_artists": [{"name": "Artist"}]
                  }
                ]
              }
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1])
    }

    func testAPageCarriedEntirelyByBlocksIsStillRead() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "blocks": [
                {
                  "items": [
                    {"playlist": {"id": 1, "owner_id": 100, "title": "Дорога"}},
                    {"playlist": {"id": 2, "owner_id": 100, "title": "Джаз"}}
                  ]
                }
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [1, 2])
    }

    // Audio rows carry id + owner_id too, and they are not playlists.
    func testAudioRowsAreNeverReadAsPlaylists() throws {
        let value = try payload(
            """
            {
              "count": 2,
              "items": [
                {
                  "id": 9, "owner_id": 100, "title": "Песня",
                  "artist": "Artist", "duration": 210
                },
                {"id": 2, "owner_id": 100, "title": "Джаз"}
              ]
            }
            """
        )

        let page = makeService().playlistPage(value, offset: 0)

        XCTAssertEqual(page.items.map(\.playlistID), [2])
    }

    func testPrefetchCoversLibrariesFullOfFollowedAlbums() {
        XCTAssertEqual(LibraryPlaylistPagePolicy.pageSize, 100)
        XCTAssertGreaterThanOrEqual(
            LibraryPlaylistPagePolicy.prefetchPages,
            20,
            "the walk must reach playlists behind hundreds of albums"
        )
        XCTAssertGreaterThanOrEqual(
            LibraryPlaylistPagePolicy.prefetchCapacity,
            2_000
        )
    }
}

final class LibraryPlaylistEntryPolicyTests: XCTestCase {
    func testNoInferredMarkerCombinationDropsAPlaylist() {
        let ambiguous: [LibraryPlaylistEntry] = [
            LibraryPlaylistEntry(vkType: 1),
            LibraryPlaylistEntry(hasMainArtists: true),
            LibraryPlaylistEntry(hasReleaseYear: true),
            LibraryPlaylistEntry(hasReleaseYear: true, vkType: 1),
            LibraryPlaylistEntry(hasMainArtists: true, vkType: 1),
            LibraryPlaylistEntry(hasMainArtists: true, hasReleaseYear: true),
            LibraryPlaylistEntry(
                hasMainArtists: true,
                hasReleaseYear: true,
                vkType: 1
            )
        ]

        for entry in ambiguous {
            XCTAssertFalse(
                LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(entry),
                "\(entry) is not evidence of a release"
            )
        }
    }

    func testAnExplicitReleaseTypeAloneIsNotEnough() {
        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(
                LibraryPlaylistEntry(albumType: "single")
            )
        )
    }

    // `type: 1` is what a playlist saved from another owner reports too, so
    // a release type next to it is not enough to take a card off the shelf.
    func testAReleaseTypeWithoutArtistAttributionStaysAPlaylist() {
        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(
                LibraryPlaylistEntry(albumType: "single", vkType: 1)
            )
        )
        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(
                LibraryPlaylistEntry(albumType: "album", hasReleaseYear: true)
            )
        )
    }

    func testATypedDatedAttributedEntryIsARelease() {
        XCTAssertTrue(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(
                LibraryPlaylistEntry(
                    albumType: "MAIN_ONLY",
                    hasMainArtists: true,
                    hasReleaseYear: true
                )
            )
        )
        XCTAssertTrue(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(
                LibraryPlaylistEntry(
                    albumType: "single",
                    hasMainArtists: true,
                    vkType: 1
                )
            )
        )
    }

    // A release that keeps its playlist card is a blemish; a playlist that
    // never arrives is the defect. The Albums shelf still gets it either
    // way, so nothing is lost by leaning this way.
    func testAnEntryTypedAsAReleaseAloneStillReachesTheAlbumsShelf() {
        let entry = LibraryPlaylistEntry(albumType: "single", vkType: 1)

        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(entry)
        )
        XCTAssertTrue(
            LibraryPlaylistEntryPolicy.belongsOnAlbumsShelf(entry)
        )
    }

    func testAPlaylistMarkerOutweighsEveryReleaseMarker() {
        let saved = LibraryPlaylistEntry(
            albumType: "album",
            hasMainArtists: true,
            hasReleaseYear: true,
            vkType: 1,
            hasOriginalPlaylist: true
        )
        XCTAssertTrue(LibraryPlaylistEntryPolicy.hasPlaylistMarker(saved))
        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(saved)
        )

        let collection = LibraryPlaylistEntry(
            albumType: "playlist",
            hasMainArtists: true,
            vkType: 1
        )
        XCTAssertFalse(
            LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(collection)
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

    // «ОНИ НЕ ВСЕ»: a fixed five-page prefetch left playlists unloaded on a
    // library whose first pages are followed albums. The opening walk now
    // runs until VK reports no further offset.
    func testInitialLoadWalksUntilVKRunsOut() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)
        let recorder = OffsetRecorder()
        let pages = 12

        await model.load { offset in
            recorder.offsets.append(offset)
            let index = offset / 100
            return MusicPage(
                items: [
                    makePlaylist(id: index + 1, title: "P\(index)")
                ],
                totalCount: pages * 100,
                nextOffset: index + 1 < pages ? offset + 100 : nil
            )
        }

        XCTAssertEqual(recorder.offsets.count, pages)
        XCTAssertEqual(model.playlists.count, pages)
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

        let recorder = OffsetRecorder()
        await model.load(pages: 5) { offset in
            recorder.offsets.append(offset)
            return MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 8,
                nextOffset: offset + 1 < 8 ? offset + 1 : nil
            )
        }

        // Resumed from the pending offset with the first page still on the
        // shelf: on 3G, restarting from zero cost the whole walk again and
        // shrank the shelf back to one card on the way through.
        XCTAssertEqual(recorder.offsets, [1, 2, 3, 4, 5])
        XCTAssertEqual(model.playlists.count, 6)
    }

    // The shelf must never go backwards while a cancelled walk is picked
    // back up — that is «сначала было восемь, стало одна» all over again.
    func testAResumedPrefetchNeverShortensTheShelf() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load(pages: 5) { offset in
            guard offset == 0 else { throw CancellationError() }
            return MusicPage(
                items: (1...4).map { makePlaylist(id: $0, title: "P\($0)") },
                totalCount: 8,
                nextOffset: 4
            )
        }
        let afterCancellation = model.playlists.count

        let shelfSizes = OffsetRecorder()
        await model.load(pages: 5) { offset in
            shelfSizes.offsets.append(model.playlists.count)
            return MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 8,
                nextOffset: offset + 1 < 8 ? offset + 1 : nil
            )
        }

        XCTAssertEqual(afterCancellation, 4)
        XCTAssertFalse(
            shelfSizes.offsets.contains { $0 < afterCancellation },
            "the shelf shrank while the walk resumed: \(shelfSizes.offsets)"
        )
        XCTAssertEqual(model.playlists.count, 8)
    }

    // One page timing out on a slow connection used to end the walk with
    // whatever had landed.
    func testATransientPageFailureIsRetriedOnce() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)
        let recorder = OffsetRecorder()

        await model.load(pages: 3) { offset in
            recorder.offsets.append(offset)
            if offset == 1, recorder.offsets.filter({ $0 == 1 }).count == 1 {
                throw URLError(.timedOut)
            }
            return MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 3,
                nextOffset: offset + 1 < 3 ? offset + 1 : nil
            )
        }

        XCTAssertEqual(recorder.offsets, [0, 1, 1, 2])
        XCTAssertEqual(model.playlists.count, 3)
        XCTAssertNil(model.errorMessage)
    }

    // A forced load — pull to refresh — is the one thing that starts over.
    func testAForcedLoadStartsTheWalkFromTheTop() async {
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

        let recorder = OffsetRecorder()
        await model.load(force: true, pages: 2) { offset in
            recorder.offsets.append(offset)
            return MusicPage(
                items: [makePlaylist(id: offset + 1, title: "P\(offset)")],
                totalCount: 8,
                nextOffset: offset + 1
            )
        }

        XCTAssertEqual(recorder.offsets, [0, 1])
        XCTAssertEqual(model.playlists.count, 2)
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

    // The reported defect: the shelf loaded all eight playlists, then the
    // Albums shelf landed and subtracted most of them again. Nothing that
    // arrives after the walk may shorten the shelf.
    func testTheShelfKeepsEveryPlaylistAfterTheAlbumsShelfLoads() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: 100)

        await model.load { _ in
            MusicPage(
                items: (1...8).map {
                    Playlist(
                        id: $0,
                        ownerID: 900 + $0,
                        title: "Сохранённый \($0)",
                        count: $0
                    )
                },
                totalCount: 8,
                nextOffset: nil
            )
        }
        XCTAssertEqual(model.playlists.count, 8)

        // The Albums shelf publishing its ids used to run through the shelf
        // here. `configure` is the only entry point left, and it carries no
        // exclusion set.
        model.configure(ownerID: 100)

        XCTAssertEqual(model.playlists.count, 8)
    }

    // A session restored before the profile lands leaves the shelf without
    // an owner id. Every playlist must still be on it.
    func testAnUnknownOwnerDoesNotShortenTheShelf() async {
        let model = PlaylistLibraryViewModel()
        model.configure(ownerID: nil)

        await model.load { _ in
            MusicPage(
                items: [
                    makePlaylist(id: 1, title: "Дорога"),
                    Playlist(id: 2, ownerID: -5, title: "Сборник", count: 10),
                    makePlaylist(id: 3, title: "Джаз")
                ],
                totalCount: 3,
                nextOffset: nil
            )
        }

        XCTAssertEqual(
            model.playlists.map(\.title),
            ["Дорога", "Сборник", "Джаз"]
        )
    }

    private func makePlaylist(id: Int, title: String) -> Playlist {
        Playlist(id: id, ownerID: 100, title: title, count: 3)
    }
}
