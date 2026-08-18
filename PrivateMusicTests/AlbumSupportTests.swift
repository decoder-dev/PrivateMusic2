import XCTest
@testable import PrivateMusic

final class AlbumDecodingTests: XCTestCase {
    func testDecodesAlbumMetadataAndNestedArtwork() throws {
        let data = """
        {
          "id": 42,
          "owner_id": -7,
          "title": "Night Drive",
          "size": 12,
          "access_key": "secret",
          "main_artists": [{"name": "Decoder"}],
          "release_date": "1722470400",
          "is_followed": 1,
          "follow_hash": "hash",
          "thumb": {"photo_600": "https://example.com/album.jpg"}
        }
        """.data(using: .utf8)!

        let album = try JSONDecoder().decode(Album.self, from: data)

        XCTAssertEqual(album.albumID, 42)
        XCTAssertEqual(album.ownerID, -7)
        XCTAssertEqual(album.id, "-7_42")
        XCTAssertEqual(album.count, 12)
        XCTAssertEqual(album.artists, ["Decoder"])
        XCTAssertTrue(album.isFollowed)
        XCTAssertNotNil(album.releaseDate)
        XCTAssertEqual(
            album.artworkURL?.absoluteString,
            "https://example.com/album.jpg"
        )
    }

    func testDecodesAlbumArtworkFromMissingCoverThumbsPayload() throws {
        let data = """
        {
          "id": 43,
          "owner_id": -7,
          "title": "Missing Cover",
          "size": 10,
          "main_artists": [{"name": "Decoder"}],
          "photo_600": "",
          "photo": "",
          "thumbs": [
            {
              "width": 300,
              "height": 300,
              "url": "http://cdn.example/missing-300.jpg"
            },
            {
              "width": 600,
              "height": 600,
              "url": "http://cdn.example/missing-600.jpg"
            }
          ]
        }
        """.data(using: .utf8)!

        let album = try JSONDecoder().decode(Album.self, from: data)

        XCTAssertEqual(
            album.artworkURL?.absoluteString,
            "https://cdn.example/missing-600.jpg"
        )
    }

    func testCatalogAlbumArtworkDecodesFromGridMosaicPayload() throws {
        let data = """
        {
          "response": {
            "blocks": [
              {
                "items": [
                  {
                    "id": 44,
                    "owner_id": -8,
                    "title": "Mosaic",
                    "year": 2024,
                    "main_artists": [{"name": "Decoder"}],
                    "photo": [],
                    "grid": {
                      "items": [
                        {"width": 270, "url": ""},
                        {
                          "width": 600,
                          "height": 600,
                          "url": "https://cdn.example/mosaic-600.jpg"
                        }
                      ]
                    }
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let albums = value.releaseAlbums

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(
            albums.first?.artworkURL?.absoluteString,
            "https://cdn.example/mosaic-600.jpg"
        )
    }

    func testReleaseAlbumsIgnoreAudioRowsWithDuration() throws {
        let data = """
        {
          "response": {
            "blocks": [
              {
                "items": [
                  {
                    "id": 101,
                    "owner_id": -8,
                    "title": "Мутный тип",
                    "duration": 187,
                    "main_artists": [{"name": "Вектор А"}],
                    "year": 2024
                  },
                  {
                    "id": 55,
                    "owner_id": -8,
                    "title": "Мутный тип",
                    "size": 1,
                    "year": 2024,
                    "main_artists": [{"name": "Вектор А"}],
                    "thumb": {"photo_600": "https://cdn.example/single.jpg"}
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let albums = value.releaseAlbums

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.albumID, 55)
        XCTAssertEqual(albums.first?.count, 1)
        XCTAssertEqual(
            albums.first?.artworkURL?.absoluteString,
            "https://cdn.example/single.jpg"
        )
    }

    func testArtistAlbumShelfPrefersCatalogWhenListIsIncomplete() {
        let thin = Album(id: 1, ownerID: -1, title: "Мутный тип", count: 0)
        XCTAssertTrue(ArtistAlbumShelfPolicy.isIncomplete(thin))
        XCTAssertTrue(
            ArtistAlbumShelfPolicy.shouldPreferCatalog(over: [thin])
        )

        let rich = Album(
            id: 1,
            ownerID: -1,
            title: "Мутный тип",
            count: 1,
            artworkURL: URL(string: "https://cdn.example/a.jpg")
        )
        XCTAssertFalse(ArtistAlbumShelfPolicy.isIncomplete(rich))
        XCTAssertFalse(
            ArtistAlbumShelfPolicy.shouldPreferCatalog(over: [rich])
        )
    }

    func testArtistAlbumShelfMergesCatalogMetadataOntoThinListEntries() {
        let thin = Album(id: 9, ownerID: -3, title: "ЛЮБИЛИ", count: 0)
        let catalog = Album(
            id: 9,
            ownerID: -3,
            title: "ЛЮБИЛИ",
            count: 1,
            artworkURL: URL(string: "https://cdn.example/loved.jpg")
        )

        let merged = ArtistAlbumShelfPolicy.merging(
            list: [thin],
            catalog: [catalog]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.count, 1)
        XCTAssertEqual(
            merged.first?.artworkURL?.absoluteString,
            "https://cdn.example/loved.jpg"
        )
    }

    func testArtistAlbumShelfDisplayFillsFromRelatedTracksAndDropsEmpty() {
        let thin = Album(id: 7, ownerID: -2, title: "Накипело", count: 0)
        let junk = Album(id: 99, ownerID: -2, title: "Ghost", count: 0)
        let tracks = [
            Track(
                trackID: 1,
                ownerID: -2,
                title: "Накипело",
                artist: "Вектор А",
                albumTitle: "Накипело",
                duration: 200,
                streamURL: nil,
                artworkURL: URL(string: "https://cdn.example/nakipelo.jpg"),
                albumReference: AlbumReference(
                    albumID: 7,
                    ownerID: -2,
                    accessKey: nil
                )
            )
        ]

        let displayed = ArtistAlbumShelfPolicy.displaying(
            [thin, junk],
            using: tracks
        )

        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed.first?.albumID, 7)
        XCTAssertEqual(displayed.first?.count, 1)
        XCTAssertEqual(
            displayed.first?.artworkURL?.absoluteString,
            "https://cdn.example/nakipelo.jpg"
        )
    }

    func testAlbumShareLinkIncludesAccessKey() {
        let album = Album(
            id: 9,
            ownerID: -3,
            title: "Album",
            count: 1,
            accessKey: "key"
        )

        XCTAssertEqual(
            AlbumShareLinkBuilder.url(for: album)?.absoluteString,
            "https://vk.com/music/album/-3_9?access_key=key"
        )
    }

    func testDecodesPlaylistPhotoArtistAndYearWithoutInventingDate() throws {
        let data = """
        {
          "id": 24,
          "owner_id": -5,
          "title": "unnamed",
          "size": 24,
          "artist": "Real Artist",
          "year": 2018,
          "photo": {"photo_600": "https://example.com/photo.jpg"}
        }
        """.data(using: .utf8)!

        let album = try JSONDecoder().decode(Album.self, from: data)

        XCTAssertEqual(album.artists, ["Real Artist"])
        XCTAssertEqual(album.releaseYear, 2018)
        XCTAssertNil(album.releaseDate)
        XCTAssertEqual(
            album.artworkURL?.absoluteString,
            "https://example.com/photo.jpg"
        )
        XCTAssertFalse(Album.isUsableTitle(album.title))
    }

    func testNormalizesUnnamedAlbumFromLoadedTracks() {
        let album = Album(
            id: 24,
            ownerID: -5,
            title: "unnamed",
            count: 0,
            releaseYear: 2018
        )
        let tracks = [
            Track(
                trackID: 1,
                ownerID: -5,
                title: "One",
                artist: "Real Artist",
                albumTitle: "Real Album",
                duration: 120,
                streamURL: nil,
                artworkURL: URL(string: "https://example.com/cover.jpg")
            ),
            Track(
                trackID: 2,
                ownerID: -5,
                title: "Two",
                artist: "Real Artist",
                albumTitle: "Real Album",
                duration: 140,
                streamURL: nil,
                artworkURL: URL(string: "https://example.com/cover.jpg")
            )
        ]

        let normalized = album.normalized(using: tracks)

        XCTAssertEqual(normalized.title, "Real Album")
        XCTAssertEqual(normalized.artists, ["Real Artist"])
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized.releaseYear, 2018)
        XCTAssertEqual(
            normalized.artworkURL?.absoluteString,
            "https://example.com/cover.jpg"
        )
    }

    func testTrackDoesNotInventOwnerForLegacyAlbumID() throws {
        let data = """
        {
          "id": 7,
          "owner_id": 8,
          "title": "Track",
          "artist": "Artist",
          "duration": 120,
          "album_id": 9
        }
        """.data(using: .utf8)!

        let track = try JSONDecoder().decode(Track.self, from: data)

        XCTAssertNil(track.albumReference)
    }

    func testAlbumWithoutTitleStillDecodesForTrackFallback() throws {
        let data = """
        {
          "id": 24,
          "owner_id": -5,
          "size": 2
        }
        """.data(using: .utf8)!

        let album = try JSONDecoder().decode(Album.self, from: data)

        XCTAssertEqual(album.title, "")
        XCTAssertFalse(Album.isUsableTitle(album.title))
    }

    func testTrackDecodesAndPersistsAlbumReference() throws {
        let data = """
        {
          "id": 7,
          "owner_id": 8,
          "title": "Track",
          "artist": "Artist",
          "duration": 120,
          "album": {
            "id": 9,
            "owner_id": -10,
            "access_key": "album-key",
            "title": "Album",
            "thumb": {"photo_600": "https://example.com/cover.jpg"}
          }
        }
        """.data(using: .utf8)!

        let track = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(track.albumReference?.albumID, 9)
        XCTAssertEqual(track.albumReference?.ownerID, -10)
        XCTAssertEqual(track.albumReference?.accessKey, "album-key")

        let restored = try JSONDecoder().decode(
            Track.self,
            from: JSONEncoder().encode(track)
        )
        XCTAssertEqual(restored.albumReference, track.albumReference)
        XCTAssertEqual(restored.artworkURL, track.artworkURL)
    }
}

@MainActor
final class LikedAlbumsStoreTests: XCTestCase {
    func testFollowAndUnfollowUpdateCompositeIdentity() {
        let store = LikedAlbumsStore()
        store.prepare(accountID: 1)
        let album = Album(
            id: 2,
            ownerID: 3,
            title: "Album",
            count: 10
        )

        store.markFollowed(album)
        XCTAssertTrue(store.contains(album))
        store.markUnfollowed(album)
        XCTAssertFalse(store.contains(album))
    }

    func testAccountChangeClearsAlbums() {
        let store = LikedAlbumsStore()
        store.prepare(accountID: 1)
        store.markFollowed(
            Album(id: 2, ownerID: 3, title: "Album", count: 10)
        )

        store.prepare(accountID: 2)

        XCTAssertTrue(store.albums.isEmpty)
    }
}

final class ListeningProgressPolicyTests: XCTestCase {
    func testRequiresThirtyPercentOfActualPlayback() {
        XCTAssertFalse(
            ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: 29.9,
                duration: 100,
                alreadyMarked: false
            )
        )
        XCTAssertTrue(
            ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: 30,
                duration: 100,
                alreadyMarked: false
            )
        )
    }

    func testAlreadyMarkedAndInvalidDurationAreRejected() {
        XCTAssertFalse(
            ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: 60,
                duration: 100,
                alreadyMarked: true
            )
        )
        XCTAssertFalse(
            ListeningProgressPolicy.shouldMarkListened(
                accumulatedPlayback: 60,
                duration: 0,
                alreadyMarked: false
            )
        )
    }
}

final class AlbumAccessPolicyTests: XCTestCase {
    func testCommunityAlbumsRequireAccessKey() {
        let community = Album(id: 1, ownerID: -200, title: "A", count: 1)
        let user = Album(id: 1, ownerID: 42, title: "A", count: 1)

        XCTAssertTrue(AlbumAccessPolicy.requiresAccessKey(community))
        XCTAssertTrue(AlbumAccessPolicy.needsAccessKeyResolution(community))
        XCTAssertFalse(AlbumAccessPolicy.requiresAccessKey(user))
        XCTAssertFalse(AlbumAccessPolicy.needsAccessKeyResolution(user))
    }

    func testWhitespaceAccessKeyIsNotUsable() {
        let album = Album(
            id: 1,
            ownerID: -200,
            title: "A",
            count: 1,
            accessKey: "   "
        )
        XCTAssertFalse(AlbumAccessPolicy.hasUsableAccessKey(album))
        XCTAssertTrue(AlbumAccessPolicy.needsAccessKeyResolution(album))
    }

    func testPreferredMatchPrefersExactIdWithAccessKey() {
        let target = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 0,
            artists: ["Сектор Газа"]
        )
        let wrongKeyless = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 12
        )
        let right = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 12,
            accessKey: "ak",
            artists: ["Сектор Газа"]
        )
        let other = Album(
            id: 99,
            ownerID: -3,
            title: "Письмо домой",
            count: 12,
            accessKey: "other",
            artists: ["Сектор Газа"]
        )

        let match = AlbumAccessPolicy.preferredMatch(
            in: [other, wrongKeyless, right],
            for: target
        )
        XCTAssertEqual(match?.accessKey, "ak")
        XCTAssertEqual(match?.compositeID, "-3_9")
    }

    func testMergingAccessMetadataKeepsLocatorAndFillsKey() {
        let thin = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 0,
            artists: ["Сектор Газа"]
        )
        let rich = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 14,
            accessKey: "secret",
            artists: ["Сектор Газа"],
            followHash: "hash"
        )
        let merged = thin.mergingAccessMetadata(from: rich)
        XCTAssertEqual(merged.accessKey, "secret")
        XCTAssertEqual(merged.count, 14)
        XCTAssertEqual(merged.followHash, "hash")
        XCTAssertEqual(merged.compositeID, thin.compositeID)
    }

    func testMergingAccessMetadataAdoptsSearchLocatorWhenIdsDiffer() {
        let stale = Album(
            id: 1,
            ownerID: -100,
            title: "Письмо домой",
            count: 0,
            artists: ["Сектор Газа"]
        )
        let searchable = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 14,
            accessKey: "album-key",
            artists: ["Сектор Газа"]
        )
        let merged = stale.mergingAccessMetadata(from: searchable)
        XCTAssertEqual(merged.compositeID, "-3_9")
        XCTAssertEqual(merged.accessKey, "album-key")
    }

    func testAudioAccessDeniedDetection() {
        XCTAssertTrue(
            AlbumAccessPolicy.isAudioAccessDenied(
                APIError.server(
                    code: 15,
                    message: "Access denied: access to users audio is denied"
                )
            )
        )
        XCTAssertFalse(
            AlbumAccessPolicy.isAudioAccessDenied(
                APIError.server(code: 10, message: "Internal server error")
            )
        )
    }

    func testSearchQueriesPreferTitleAndArtistCombos() {
        let album = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 0,
            artists: ["Сектор Газа"]
        )
        let queries = AlbumAccessPolicy.searchQueries(for: album)
        XCTAssertEqual(queries.first, "Письмо домой Сектор Газа")
        XCTAssertTrue(queries.contains("Письмо домой"))
        XCTAssertTrue(queries.contains("Сектор Газа"))
    }

    func testTrackBelongsMatchesAlbumTitleAndArtist() {
        let album = Album(
            id: 9,
            ownerID: -3,
            title: "Письмо домой",
            count: 0,
            artists: ["Сектор Газа"]
        )
        let matching = Track(
            trackID: 1,
            ownerID: 2,
            title: "Лирика",
            artist: "Сектор Газа",
            albumTitle: "Письмо домой",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
        let other = Track(
            trackID: 2,
            ownerID: 2,
            title: "Other",
            artist: "Other Band",
            albumTitle: "Письмо домой",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
        XCTAssertTrue(AlbumAccessPolicy.trackBelongs(matching, to: album))
        XCTAssertFalse(AlbumAccessPolicy.trackBelongs(other, to: album))
    }
}

@MainActor
final class HomeCatalogStoreTests: XCTestCase {
    func testFreshContentDoesNotRefreshAgain() {
        let store = HomeCatalogStore()
        store.prepare(accountID: 1)
        store.finish(
            recommendations: [],
            mixes: [.common],
            errorMessage: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertFalse(
            store.shouldRefresh(
                force: false,
                now: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertTrue(
            store.shouldRefresh(
                force: true,
                now: Date(timeIntervalSince1970: 200)
            )
        )
    }

    func testAccountChangeClearsHomeContent() {
        let store = HomeCatalogStore()
        store.prepare(accountID: 1)
        store.finish(
            recommendations: [],
            mixes: [.common],
            errorMessage: nil
        )

        store.prepare(accountID: 2)

        XCTAssertTrue(store.isEmpty)
    }
}
