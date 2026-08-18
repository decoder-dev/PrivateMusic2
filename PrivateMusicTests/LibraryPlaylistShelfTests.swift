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

    // VK hands out «Мне нравится (2)» when the liked playlist is saved
    // again. It has its own id and its own tracks, and the user expects
    // both cards — collapsing it took a real playlist off Медиатека.
    func testShelfKeepsNumberedLikedClonesAsSeparateCards() throws {
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

        XCTAssertEqual(shelf.map(\.id), [liked.id, clone.id])
    }

    func testShelfKeepsDistinctUserPlaylistsWithNumberedTitles() throws {
        let rock = try makePlaylist(id: 4, ownerID: 100, title: "rock")
        let rockTwo = try makePlaylist(id: 5, ownerID: 100, title: "Рок (2)")

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [rock, rockTwo],
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), [rock.id, rockTwo.id])
    }

    // The library in the report: eight playlists, «Мне нравится» and «Мне
    // нравится (2)» among them, rendered as one card.
    func testTheReportedLibraryRendersEveryCard() throws {
        var library = [
            try makePlaylist(
                id: 1,
                ownerID: 100,
                title: "Мне нравится",
                count: 118
            ),
            try makePlaylist(
                id: 2,
                ownerID: 100,
                title: "Мне нравится (2)",
                count: 12
            )
        ]
        library += try (3...8).map { index in
            try makePlaylist(
                id: index,
                ownerID: 900 + index,
                title: "Сохранённый \(index)"
            )
        }

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            library,
            ownerID: 100
        )

        XCTAssertEqual(shelf.map(\.id), library.map(\.id))
    }

    func testShelfKeepsPlaylistsPeopleNameLikeFavourites() throws {
        // Regression: collapsing every "favourites" wording wiped real
        // playlists off Медиатека. Only the VK system liked playlist
        // collapses by title.
        let mine = try makePlaylist(id: 11, ownerID: 100, title: "Избранное")
        let theirs = try makePlaylist(id: 12, ownerID: 700, title: "Избранное")
        let loved = try makePlaylist(id: 13, ownerID: 100, title: "Любимое")
        let favorites = try makePlaylist(
            id: 14,
            ownerID: 800,
            title: "Favorites"
        )

        let shelf = LibraryPlaylistShelfPolicy.normalized(
            [mine, theirs, loved, favorites],
            ownerID: 100
        )

        XCTAssertEqual(
            shelf.map(\.id),
            [mine.id, theirs.id, loved.id, favorites.id]
        )
    }

    func testFavouriteWordingIsNotTreatedAsTheSystemLikedPlaylist() {
        for title in [
            "Избранное",
            "Любимое",
            "Любимые треки",
            "Favorites",
            "Favourites"
        ] {
            XCTAssertNil(
                LibraryPlaylistShelfPolicy.likedKey(for: title),
                "\(title) is a user playlist name, not the VK liked playlist"
            )
        }
    }

    func testShelfPreservesOrderOfUntouchedPlaylists() throws {
        let first = try makePlaylist(id: 4, ownerID: 100, title: "rock")
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

    // Nothing is stripped off the end of a title any more: a trailing
    // marker is part of the name VK gave the playlist, and treating it as
    // noise merged two separate playlists into one card.
    func testTitleFoldingKeepsTrailingMarkers() {
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Мне нравится (2)"),
            "мне нравится (2)"
        )
        XCTAssertNotEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Мне нравится (2)"),
            LibraryPlaylistShelfPolicy.normalizedTitle("мне нравится")
        )
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("Дорога #3"),
            "дорога #3"
        )
        XCTAssertEqual(
            LibraryPlaylistShelfPolicy.normalizedTitle("  МНЁ \n НРАВИТСЯ  "),
            "мне нравится",
            "case, ё and stray whitespace still fold"
        )
        XCTAssertNil(
            LibraryPlaylistShelfPolicy.likedKey(for: "Мне нравится (2)"),
            "a numbered clone is a playlist of its own"
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

    func testShelfHidesPlaylistsThatAlreadyLiveOnTheAlbumsShelf() throws {
        let albumAsPlaylist = try makePlaylist(
            id: 42,
            ownerID: 100,
            title: "Release"
        )
        let realPlaylist = try makePlaylist(
            id: 7,
            ownerID: 100,
            title: "Road mix"
        )
        let filtered = LibraryPlaylistShelfPolicy.excludingLikedAlbums(
            [albumAsPlaylist, realPlaylist],
            likedAlbumCompositeIDs: ["100_42"]
        )

        XCTAssertEqual(filtered.map(\.libraryIdentity), ["100_7"])
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
