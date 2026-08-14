import XCTest
@testable import PrivateMusic

/// «Очередь понравившихся треков в библиотеке — они играют в разнобой, но не
/// по порядку»: tapping a track in Медиатека must queue the visible list, in
/// the visible order, from the tapped row.
@MainActor
final class LibraryPlaybackOrderTests: XCTestCase {
    func testPlayingALibraryTrackQueuesTheListInOrderFromThatRow() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 12)

        context.player.play(library[4], in: library)

        XCTAssertEqual(
            context.player.queue.map(\.id),
            library.map(\.id)
        )
        XCTAssertEqual(context.player.currentIndex, 4)
        XCTAssertEqual(context.player.currentTrack?.id, library[4].id)
        XCTAssertEqual(
            upcoming(in: context.player),
            library.dropFirst(5).map(\.id)
        )
    }

    func testEveryLibraryRowStartsTheSameOrderedQueue() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 8)

        for index in library.indices {
            context.player.play(library[index], in: library)
            XCTAssertEqual(
                context.player.queue.map(\.id),
                library.map(\.id),
                "row \(index) must not reorder the library"
            )
            XCTAssertEqual(context.player.currentIndex, index)
        }
    }

    // The reported defect: «Перемешать» on an album or a mix turned the
    // player-wide flag on, so every later tap in Медиатека built a shuffled
    // queue for the rest of the session.
    func testCollectionShuffleDoesNotLatchTheNextLibraryQueue() {
        let context = makePlayer()
        defer { context.tearDown() }
        let album = tracks(count: 30, idOffset: 500)
        let library = tracks(count: 30)

        context.player.playShuffled(in: album, source: .album(title: "A"))
        XCTAssertTrue(context.player.shuffleEnabled)

        context.player.play(library[2], in: library)

        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue.map(\.id), library.map(\.id))
        XCTAssertEqual(context.player.currentIndex, 2)
    }

    // A library queue used to be captioned as a mix seeded by the tapped
    // track, which is not what is playing.
    func testALibraryQueueNamesItselfInThePlayer() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 6)

        context.player.play(library[1], in: library, source: .library)

        XCTAssertEqual(context.player.queueSource, .library)
        XCTAssertEqual(
            context.player.queueContextTitle,
            L10n.text("library.your_tracks")
        )
    }

    // «Перемешать» over the library shuffles the queue it starts and
    // nothing else: the next tap on a row still plays in list order.
    func testShufflingTheLibraryDoesNotLatchTheNextLibraryQueue() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 30)

        context.player.playShuffled(in: library, source: .library)

        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queueSource, .library)
        XCTAssertEqual(
            context.player.queueContextTitle,
            L10n.text("library.your_tracks")
        )
        XCTAssertEqual(
            Set(context.player.queue.map(\.id)),
            Set(library.map(\.id))
        )
        XCTAssertFalse(
            context.defaults.bool(forKey: PlaybackShufflePreference.key)
        )

        context.player.play(library[3], in: library, source: .library)

        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue.map(\.id), library.map(\.id))
        XCTAssertEqual(context.player.currentIndex, 3)
    }

    // The library header disables «Перемешать» while the list is empty
    // (loading, an empty library, or a search with no matches), but
    // `playShuffled` guards the same case on its own so an empty collection
    // never crashes or starts an empty queue.
    func testShufflingAnEmptyCollectionDoesNothing() {
        let context = makePlayer()
        defer { context.tearDown() }

        context.player.playShuffled(in: [], source: .library)

        XCTAssertNil(context.player.currentTrack)
        XCTAssertTrue(context.player.queue.isEmpty)
        XCTAssertNil(context.player.queueSource)
    }

    // A search filter narrows the visible list without touching the loaded
    // library page: shuffling the filtered rows must only ever queue what
    // matched, never the untouched rest of the library.
    func testShufflingAFilteredSearchResultOnlyQueuesTheMatches() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 20)
        let filtered = Array(library[2..<5])

        context.player.playShuffled(in: filtered, source: .library)

        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertEqual(
            Set(context.player.queue.map(\.id)),
            Set(filtered.map(\.id))
        )
        XCTAssertEqual(context.player.queue.count, filtered.count)
    }

    func testCollectionShuffleDoesNotPersistThePreference() {
        let context = makePlayer()
        defer { context.tearDown() }

        context.player.playShuffled(in: tracks(count: 20, idOffset: 500))

        XCTAssertFalse(
            context.defaults.bool(forKey: PlaybackShufflePreference.key)
        )
        let relaunched = AudioPlayer(
            settings: AppSettings(defaults: context.defaults),
            historyStore: ListeningHistoryStore(defaults: context.defaults),
            defaults: context.defaults
        )
        XCTAssertFalse(relaunched.shuffleEnabled)
    }

    // Shuffle is still a real setting: the library follows the control the
    // user set, and turning it back off replays the list order.
    func testTheShuffleControlStillAppliesToTheLibraryAndIsReversible() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 40)

        context.player.play(library[0], in: library)
        context.player.toggleShuffle()
        XCTAssertTrue(context.player.shuffleEnabled)

        context.player.play(library[3], in: library)
        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.currentTrack?.id, library[3].id)
        XCTAssertEqual(
            Set(context.player.queue.map(\.id)),
            Set(library.map(\.id))
        )

        context.player.toggleShuffle()

        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue.map(\.id), library.map(\.id))
        XCTAssertEqual(context.player.currentIndex, 3)
    }

    // Builds up to 3.28.62 persisted `player.shuffle` from the per-collection
    // «Перемешать» button, so upgraded installs still carried a latched
    // shuffle that no amount of client-side fixing could see.
    func testTheLegacyPersistedCollectionLatchIsClearedOnce() {
        let suite = "LibraryPlaybackOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PlaybackShufflePreference.key)

        XCTAssertFalse(PlaybackShufflePreference.resolve(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: PlaybackShufflePreference.key))

        // Anything the user sets afterwards is a real preference again.
        PlaybackShufflePreference.store(true, in: defaults)
        XCTAssertTrue(PlaybackShufflePreference.resolve(defaults: defaults))
    }

    func testDeliberateShuffleSurvivesRelaunch() {
        let context = makePlayer()
        defer { context.tearDown() }
        let library = tracks(count: 10)

        context.player.play(library[0], in: library)
        context.player.toggleShuffle()

        let relaunched = AudioPlayer(
            settings: AppSettings(defaults: context.defaults),
            historyStore: ListeningHistoryStore(defaults: context.defaults),
            defaults: context.defaults
        )
        XCTAssertTrue(relaunched.shuffleEnabled)
    }

    private func upcoming(in player: AudioPlayer) -> [String] {
        guard let index = player.currentIndex else { return [] }
        return player.queue.dropFirst(index + 1).map(\.id)
    }

    private func tracks(count: Int, idOffset: Int = 0) -> [Track] {
        (0..<count).map { index in
            Track(
                trackID: idOffset + index + 1,
                ownerID: 10,
                title: "Track \(idOffset + index + 1)",
                artist: "Artist \(index % 4)",
                duration: 180,
                streamURL: nil,
                artworkURL: nil
            )
        }
    }

    private struct PlayerContext {
        let player: AudioPlayer
        let defaults: UserDefaults
        let suite: String

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makePlayer() -> PlayerContext {
        let suite = "LibraryPlaybackOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return PlayerContext(
            player: AudioPlayer(
                settings: AppSettings(defaults: defaults),
                historyStore: ListeningHistoryStore(defaults: defaults),
                defaults: defaults
            ),
            defaults: defaults,
            suite: suite
        )
    }
}

final class LibraryTrackContinuationCursorTests: XCTestCase {
    func testTheCursorContinuesInLibraryOrder() async throws {
        let service = LibraryPagingMusicService(pageSize: 4, totalCount: 12)
        let cursor = LibraryTrackContinuationCursor(
            startingOffset: 4,
            knownTracks: try await service.page(offset: 0).items,
            pageSize: 4
        )

        let second = try await cursor.next(
            accessToken: "t",
            musicService: service
        )
        let third = try await cursor.next(
            accessToken: "t",
            musicService: service
        )

        XCTAssertEqual(second.map(\.id), ["10_5", "10_6", "10_7", "10_8"])
        XCTAssertEqual(third.map(\.id), ["10_9", "10_10", "10_11", "10_12"])
        let offsets = await service.requestedOffsets
        XCTAssertEqual(offsets, [0, 4, 8])
    }

    func testTheCursorNeverRepeatsATrackTheQueueAlreadyHas() async throws {
        let service = LibraryPagingMusicService(pageSize: 4, totalCount: 8)
        let cursor = LibraryTrackContinuationCursor(
            startingOffset: 0,
            knownTracks: try await service.page(offset: 0).items,
            pageSize: 4
        )

        let additions = try await cursor.next(
            accessToken: "t",
            musicService: service
        )

        XCTAssertTrue(additions.isEmpty)
    }

    // Radio must not stop at the end of the library.
    func testTheCursorFallsBackToRecommendationsOnceTheLibraryEnds()
        async throws {
        let service = LibraryPagingMusicService(pageSize: 4, totalCount: 4)
        let cursor = LibraryTrackContinuationCursor(
            startingOffset: 4,
            pageSize: 4
        )

        let additions = try await cursor.next(
            accessToken: "t",
            musicService: service
        )

        XCTAssertEqual(additions.map(\.artist), ["Recommended"])
    }

    func testThePrefetchCursorStopsBeforeRecommendationsOnceLibraryEnds()
        async throws {
        let service = LibraryPagingMusicService(pageSize: 4, totalCount: 4)
        let cursor = LibraryTrackContinuationCursor(
            startingOffset: 4,
            pageSize: 4
        )

        let additions = try await cursor.nextLibraryPage(
            accessToken: "t",
            musicService: service
        )

        XCTAssertTrue(additions.isEmpty)
    }
}

/// Library pages in VK order plus a one-track recommendation tail.
private actor LibraryPagingMusicService: MusicService {
    private(set) var requestedOffsets: [Int] = []
    private let pageSize: Int
    private let totalCount: Int

    init(pageSize: Int, totalCount: Int) {
        self.pageSize = pageSize
        self.totalCount = totalCount
    }

    func page(offset: Int) async throws -> MusicPage<Track> {
        try await library(accessToken: "t", offset: offset, count: pageSize)
    }

    func configure(userAgent: String?) async {}

    func profile(accessToken: String) async throws -> UserProfile {
        throw APIError.invalidResponse
    }

    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        requestedOffsets.append(offset)
        let upper = min(offset + count, totalCount)
        guard offset < upper else {
            return MusicPage(items: [], totalCount: totalCount, nextOffset: nil)
        }
        let items = (offset..<upper).map {
            Track(
                trackID: $0 + 1,
                ownerID: 10,
                title: "Track \($0 + 1)",
                artist: "Artist",
                duration: 120,
                streamURL: nil,
                artworkURL: nil
            )
        }
        return MusicPage(
            items: items,
            totalCount: totalCount,
            nextOffset: upper < totalCount ? upper : nil
        )
    }

    func recommendations(
        accessToken: String,
        targetAudio: String?,
        shuffle: Bool
    ) async throws -> [Track] {
        [
            Track(
                trackID: 9_001,
                ownerID: 10,
                title: "Radio",
                artist: "Recommended",
                duration: 120,
                streamURL: nil,
                artworkURL: nil
            )
        ]
    }

    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        track
    }

    func mixes(accessToken: String) async throws -> [MusicMix] { [] }

    func catalogSnapshot(
        accessToken: String
    ) async throws -> VKCatalogSnapshot {
        throw APIError.invalidResponse
    }

    func newReleases(accessToken: String) async throws -> [Album] {
        throw APIError.invalidResponse
    }

    func mixTracks(
        _ mix: MusicMix,
        accessToken: String,
        startingOffset: Int,
        pages: Int
    ) async throws -> [Track] {
        throw APIError.invalidResponse
    }

    func search(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        throw APIError.invalidResponse
    }

    func searchArtists(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> [VKArtist] {
        throw APIError.invalidResponse
    }

    func artistTracks(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        throw APIError.invalidResponse
    }

    func artistAlbums(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        throw APIError.invalidResponse
    }

    func searchAlbums(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        throw APIError.invalidResponse
    }

    func likedAlbums(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        throw APIError.invalidResponse
    }

    func albumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        throw APIError.invalidResponse
    }

    func resolvedAlbum(
        _ album: Album,
        accessToken: String
    ) async throws -> Album {
        throw APIError.invalidResponse
    }

    func toggleAlbumFollow(
        _ album: Album,
        follow: Bool,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }

    func playlists(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist> {
        throw APIError.invalidResponse
    }

    func playlistTracks(
        _ playlist: Playlist,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        throw APIError.invalidResponse
    }

    func addToLibrary(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        throw APIError.invalidResponse
    }

    func removeFromLibrary(
        _ track: Track,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }

    func lyrics(
        for track: Track,
        accessToken: String
    ) async throws -> Lyrics {
        throw APIError.invalidResponse
    }

    func createPlaylist(
        title: String,
        description: String,
        ownerID: Int,
        accessToken: String
    ) async throws -> Playlist {
        throw APIError.invalidResponse
    }

    func editPlaylist(
        _ playlist: Playlist,
        title: String,
        description: String,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }

    func deletePlaylist(
        _ playlist: Playlist,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }

    func add(
        _ track: Track,
        to playlist: Playlist,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }

    func remove(
        _ track: Track,
        from playlist: Playlist,
        accessToken: String
    ) async throws {
        throw APIError.invalidResponse
    }
}
