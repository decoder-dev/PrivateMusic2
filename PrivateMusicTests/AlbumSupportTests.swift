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

@MainActor
final class HomeCatalogStoreTests: XCTestCase {
    func testFreshContentDoesNotRefreshAgain() {
        let store = HomeCatalogStore()
        store.prepare(accountID: 1)
        store.finish(
            recommendations: [],
            mixes: [.common],
            playlists: [],
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
            playlists: [],
            errorMessage: nil
        )

        store.prepare(accountID: 2)

        XCTAssertTrue(store.isEmpty)
    }
}
