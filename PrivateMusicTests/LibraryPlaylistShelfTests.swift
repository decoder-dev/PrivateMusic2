import XCTest
@testable import PrivateMusic

final class LibraryPlaylistShelfTests: XCTestCase {
    func testPlaylistIdentityIsScopedToItsOwner() throws {
        let mine = try makePlaylist(id: 7, ownerID: 100, title: "Дорога")
        let theirs = try makePlaylist(id: 7, ownerID: 200, title: "Road")

        XCTAssertEqual(mine.playlistID, theirs.playlistID)
        XCTAssertNotEqual(
            mine.id,
            theirs.id,
            "colliding ForEach ids collapse the shelf into reused cards"
        )
        XCTAssertEqual(mine.id, "100_7")
        XCTAssertEqual(mine.id, mine.libraryIdentity)
    }

    func testShelfDropsTheSamePlaylistReturnedTwice() throws {
        let liked = try makePlaylist(
            id: 1,
            ownerID: 100,
            title: "Мне нравится"
        )

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [liked, liked],
            ownerID: 100
        )

        XCTAssertEqual(shelf.count, 1)
    }

    func testShelfKeepsTheOwnedCopyOfTheLikedPlaylist() throws {
        let followed = try makePlaylist(
            id: 3,
            ownerID: 555,
            title: "Мне нравится",
            count: 2
        )
        let owned = try makePlaylist(
            id: 9,
            ownerID: 100,
            title: "Мне нравится",
            count: 118
        )

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [followed, owned],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), [owned.id])
    }

    func testShelfCollapsesNumberedLikedClones() throws {
        let liked = try makePlaylist(
            id: 1,
            ownerID: 100,
            title: "Мне нравится",
            count: 118
        )
        let clone = try makePlaylist(
            id: 2,
            ownerID: 100,
            title: "Мне нравится (2)",
            count: 2
        )

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [liked, clone],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), [liked.id])
    }

    func testShelfKeepsDistinctUserPlaylistsWithNumberedTitles() throws {
        let rock = try makePlaylist(id: 4, ownerID: 100, title: "Рок")
        let rockTwo = try makePlaylist(id: 5, ownerID: 100, title: "Рок (2)")

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [rock, rockTwo],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), [rock.id, rockTwo.id])
    }

    func testShelfPreservesOrderOfUntouchedPlaylists() throws {
        let first = try makePlaylist(id: 4, ownerID: 100, title: "Рок")
        let liked = try makePlaylist(
            id: 1,
            ownerID: 100,
            title: "Мне нравится"
        )
        let last = try makePlaylist(id: 6, ownerID: 100, title: "Джаз")

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [first, liked, last],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), [first.id, liked.id, last.id])
    }

    func testLikedTitleMatchingIgnoresCaseAndYo() {
        XCTAssertNotNil(
            LibraryPlaylistShelfPolicy.likedKey(for: "МНЕ НРАВИТСЯ")
        )
        XCTAssertNotNil(
            LibraryPlaylistShelfPolicy.likedKey(for: " Liked Songs ")
        )
        XCTAssertNil(LibraryPlaylistShelfPolicy.likedKey(for: "Мне нравится это"))
    }

    func testCloneMarkerStripping() {
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Мне нравится (2)"),
            LibraryPlaylistShelfPolicy.normalizedTitle("мне нравится")
        )
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Дорога #3"),
            "дорога"
        )
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Trip (2019)"),
            "trip",
            "a trailing year reads as a clone marker; only liked titles use it"
        )
    }

    func testShelfCardStaysArtworkFirst() {
        XCTAssertEqual(
            LibraryShelfMetrics.cardHeight,
            LibraryShelfMetrics.artworkSize
                + LibraryShelfMetrics.captionSpacing
                + LibraryShelfMetrics.captionHeight
        )
        XCTAssertGreaterThan(
            LibraryShelfMetrics.shelfHeight,
            LibraryShelfMetrics.artworkSize,
            "the pinned shelf row must fit a full square cover"
        )
        XCTAssertGreaterThan(
            LibraryShelfMetrics.artworkHeightRatio,
            0.6,
            "a caption-dominated card is the text-tab regression"
        )
    }

    private func makePlaylist(
        id: Int,
        ownerID: Int,
        title: String,
        count: Int = 10
    ) throws -> Playlist {
        let object: [String: Any] = [
            "id": id,
            "owner_id": ownerID,
            "title": title,
            "count": count
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Playlist.self, from: data)
    }
}
