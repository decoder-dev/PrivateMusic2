import XCTest
@testable import PrivateMusic

final class MixRationaleTests: XCTestCase {
    func testBuildsArtistOverlapFromHistory() {
        let historyTrack = makeTrack(id: 1, artist: "Daft Punk")
        let mixTrack = makeTrack(id: 2, artist: "Daft Punk")
        let rationale = MixRationaleBuilder.build(
            mixTracks: [mixTrack],
            history: [
                ListeningHistoryEntry(track: historyTrack, playedAt: Date())
            ]
        )
        XCTAssertFalse(rationale.isEmpty)
        XCTAssertTrue(
            rationale.lines.contains { $0.contains("Daft Punk") }
        )
    }

    func testRecommendationOverlapNamesTheMostRepresentedArtist() {
        let mixTracks = [
            makeTrack(id: 1, artist: "Alpha"),
            makeTrack(id: 2, artist: "Beta"),
            makeTrack(id: 3, artist: "Beta"),
            makeTrack(id: 4, artist: "Gamma")
        ]
        let rationale = MixRationaleBuilder.build(
            mixTracks: mixTracks,
            history: [],
            recommendations: mixTracks
        )
        XCTAssertTrue(rationale.lines.contains { $0.hasSuffix("Beta") })
        XCTAssertFalse(
            rationale.lines.contains {
                $0.hasSuffix("Alpha") || $0.hasSuffix("Gamma")
            }
        )
    }

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Song \(id)",
            artist: artist,
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

final class MixQueueRankerTests: XCTestCase {
    func testCloserToSeedPrefersSameArtistFirst() {
        var rng = SeededGenerator(seed: 7)
        let seed = makeTrack(id: 1, artist: "Alpha")
        let same = makeTrack(id: 2, artist: "Alpha")
        let other = makeTrack(id: 3, artist: "Beta")
        let ranked = MixQueueRanker.rerank(
            queue: [seed, other, same],
            currentIndex: 0,
            seed: seed,
            mode: .closerToSeed,
            rng: &rng
        )
        XCTAssertEqual(ranked.first?.id, seed.id)
        XCTAssertEqual(ranked[1].id, same.id)
        XCTAssertEqual(ranked[2].id, other.id)
    }

    func testMoreNovelPushesFamiliarArtistsDown() {
        var rng = SeededGenerator(seed: 11)
        let seed = makeTrack(id: 1, artist: "Alpha")
        let familiar = makeTrack(id: 2, artist: "Alpha")
        let novel = makeTrack(id: 3, artist: "Zeta")
        let ranked = MixQueueRanker.rerank(
            queue: [seed, familiar, novel],
            currentIndex: 0,
            seed: seed,
            mode: .moreNovel,
            historyArtists: ["Alpha"],
            rng: &rng
        )
        XCTAssertEqual(ranked.map(\.id), [seed.id, novel.id, familiar.id])
    }

    func testBalancedBreaksArtistClusters() {
        var rng = SeededGenerator(seed: 42)
        let seed = makeTrack(id: 1, artist: "Alpha")
        let clustered = [
            seed,
            makeTrack(id: 2, artist: "Alpha"),
            makeTrack(id: 3, artist: "Alpha"),
            makeTrack(id: 4, artist: "Alpha"),
            makeTrack(id: 5, artist: "Beta"),
            makeTrack(id: 6, artist: "Gamma"),
            makeTrack(id: 7, artist: "Delta"),
            makeTrack(id: 8, artist: "Epsilon")
        ]
        let originalUpcoming = clustered.dropFirst().map(\.artist)
        var originalRepeats = 0
        for index in originalUpcoming.indices.dropFirst() {
            if originalUpcoming[index] == originalUpcoming[index - 1] {
                originalRepeats += 1
            }
        }

        let ranked = MixQueueRanker.rerank(
            queue: clustered,
            currentIndex: 0,
            seed: seed,
            mode: .balanced,
            rng: &rng
        )
        let upcomingArtists = ranked.dropFirst().map(\.artist)
        var immediateRepeats = 0
        for index in upcomingArtists.indices.dropFirst() {
            if upcomingArtists[index] == upcomingArtists[index - 1] {
                immediateRepeats += 1
            }
        }
        XCTAssertLessThan(
            immediateRepeats,
            originalRepeats,
            "Balanced radio should reduce immediate artist repeats vs VK order"
        )
        XCTAssertEqual(ranked.first?.id, seed.id)
        XCTAssertNotEqual(ranked.map(\.id), clustered.map(\.id))
    }

    func testBalancedChangesClusteredOrder() {
        var rng = SeededGenerator(seed: 99)
        let seed = makeTrack(id: 1, artist: "A")
        let original = [
            seed,
            makeTrack(id: 2, artist: "A"),
            makeTrack(id: 3, artist: "B"),
            makeTrack(id: 4, artist: "A"),
            makeTrack(id: 5, artist: "C"),
            makeTrack(id: 6, artist: "B")
        ]
        let ranked = MixQueueRanker.rerank(
            queue: original,
            currentIndex: 0,
            seed: seed,
            mode: .balanced,
            rng: &rng
        )
        XCTAssertNotEqual(
            ranked.map(\.id),
            original.map(\.id),
            "Balanced must no longer be a no-op on clustered queues"
        )
    }

    func testPublicRerankIsDeterministicForSameQueue() {
        let seed = makeTrack(id: 1, artist: "Alpha")
        let queue = [
            seed,
            makeTrack(id: 2, artist: "Beta"),
            makeTrack(id: 3, artist: "Gamma"),
            makeTrack(id: 4, artist: "Beta"),
            makeTrack(id: 5, artist: "Delta"),
            makeTrack(id: 6, artist: "Epsilon")
        ]
        let first = MixQueueRanker.rerank(
            queue: queue,
            currentIndex: 0,
            seed: seed,
            mode: .balanced
        )
        let second = MixQueueRanker.rerank(
            queue: queue,
            currentIndex: 0,
            seed: seed,
            mode: .balanced
        )
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Song \(id)",
            artist: artist,
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

final class SelenaRecommendationComposerTests: XCTestCase {
    func testComposeInterleavesPersonalAndSimilarRecommendations() {
        let seed = makeTrack(id: 1, artist: "Seed")
        let personal = [
            makeTrack(id: 2, artist: "Personal"),
            makeTrack(id: 3, artist: "Personal")
        ]
        let similar = [
            makeTrack(id: 4, artist: "Similar"),
            makeTrack(id: 5, artist: "Similar")
        ]

        let result = SelenaRecommendationComposer.compose(
            seedTracks: [seed],
            personalRecommendations: personal,
            similarRecommendations: similar,
            limit: 6
        ).tracks

        XCTAssertEqual(
            result.map(\.id),
            ["1_2", "1_4", "1_3", "1_5", seed.id]
        )
    }

    func testSeedTracksDeduplicateHistoryLoadedAndRecommendations() {
        let duplicate = makeTrack(id: 7, artist: "Dup")
        let history = [
            ListeningHistoryEntry(track: duplicate, playedAt: Date()),
            ListeningHistoryEntry(
                track: makeTrack(id: 8, artist: "History"),
                playedAt: Date()
            )
        ]

        let seeds = SelenaRecommendationComposer.seedTracks(
            history: history,
            recommendations: [
                duplicate,
                makeTrack(id: 10, artist: "Recommendation")
            ],
            loaded: [
                makeTrack(id: 9, artist: "Loaded"),
                duplicate
            ]
        )

        XCTAssertEqual(
            seeds.map(\.id),
            ["1_7", "1_8", "1_9", "1_10"]
        )
    }

    func testMixContinuationCursorAdvancesOffsetsForInfiniteStream()
        async throws {
        let service = CursorMusicService()
        let cursor = MixTrackContinuationCursor(mix: .common)

        _ = try await cursor.next(
            accessToken: "token",
            musicService: service
        )
        _ = try await cursor.next(
            accessToken: "token",
            musicService: service
        )

        let expectedStart = MixTrackRequestPolicy.bootstrapPages
            * MixTrackRequestPolicy.pageSize
        let expectedNext = expectedStart
            + MixTrackRequestPolicy.continuationPages
            * MixTrackRequestPolicy.pageSize
        let offsets = await service.mixOffsets
        let pages = await service.mixPages
        XCTAssertEqual(offsets, [expectedStart, expectedNext])
        XCTAssertEqual(
            pages,
            Array(repeating: MixTrackRequestPolicy.continuationPages, count: 2)
        )
    }

    func testSelenaCursorKeepsRequestingSeededRecommendations()
        async throws {
        let service = CursorMusicService()
        let seeds = (1...4).map { makeTrack(id: $0, artist: "Seed \($0)") }
        let cursor = SelenaRecommendationCursor(
            seedTracks: seeds,
            knownTracks: [seeds[0]]
        )

        let firstPage = try await cursor.next(
            accessToken: "token",
            musicService: service
        ).tracks
        let secondPage = try await cursor.next(
            accessToken: "token",
            musicService: service
        ).tracks

        let recommendationTargets = await service.recommendationTargets
        let seededTargets = recommendationTargets.compactMap {
            $0
        }
        XCTAssertFalse(firstPage.isEmpty)
        XCTAssertFalse(secondPage.isEmpty)
        // Parallel seed fan-out does not preserve call order — only that
        // the first page asked for the first three seeds.
        XCTAssertEqual(
            Set(seededTargets.prefix(3)),
            Set(seeds.prefix(3).map(\.id))
        )
        XCTAssertGreaterThanOrEqual(seededTargets.count, 6)
        XCTAssertEqual(
            Set((firstPage + secondPage).map(\.id)).count,
            firstPage.count + secondPage.count
        )
    }

    func testSelenaCursorReusesCachedPersonalRecommendations() async throws {
        let service = CursorMusicService()
        let seeds = (1...3).map { makeTrack(id: $0, artist: "Seed \($0)") }
        let cached = [
            makeTrack(id: 50, artist: "Cached"),
            makeTrack(id: 51, artist: "Cached")
        ]
        let cursor = SelenaRecommendationCursor(
            seedTracks: seeds,
            knownTracks: []
        )

        let page = try await cursor.next(
            accessToken: "token",
            musicService: service,
            cachedPersonalRecommendations: cached
        ).tracks

        let recommendationTargets = await service.recommendationTargets
        // Cached personal skips the unseeded recommendations() call
        // (recorded as a nil target).
        XCTAssertFalse(recommendationTargets.contains { $0 == nil })
        XCTAssertTrue(page.contains { $0.artist == "Cached" })
    }

    func testRotatingSeedsPreferFreshlyComposedTracks() {
        let previous = (1...32).map { makeTrack(id: $0, artist: "Old \($0)") }
        let composed = [
            makeTrack(id: 100, artist: "New A"),
            makeTrack(id: 101, artist: "New B"),
            makeTrack(id: 102, artist: "New C")
        ]

        let rotated = SelenaRecommendationComposer.rotatingSeeds(
            previous: previous,
            composed: composed,
            limit: 32
        )

        XCTAssertEqual(
            Array(rotated.prefix(3).map(\.id)),
            ["1_100", "1_101", "1_102"]
        )
        XCTAssertEqual(rotated.count, 32)
        // Tail of the previous window falls off first — not the head.
        XCTAssertFalse(rotated.contains { $0.id == "1_32" })
        XCTAssertTrue(rotated.contains { $0.id == "1_1" })
    }

    func testSelenaCursorReusesSessionPersonalOnLaterPages() async throws {
        let service = CursorMusicService()
        let seeds = (1...3).map { makeTrack(id: $0, artist: "Seed \($0)") }
        let cached = [
            makeTrack(id: 70, artist: "Session"),
            makeTrack(id: 71, artist: "Session")
        ]
        let cursor = SelenaRecommendationCursor(
            seedTracks: seeds,
            knownTracks: []
        )

        _ = try await cursor.next(
            accessToken: "token",
            musicService: service,
            cachedPersonalRecommendations: cached
        )
        let beforeSecond = await service.recommendationTargets.count
        let second = try await cursor.next(
            accessToken: "token",
            musicService: service
        ).tracks
        let targets = await service.recommendationTargets

        // Second page must not pay for another unseeded personal fetch.
        XCTAssertFalse(targets.contains { $0 == nil })
        XCTAssertEqual(targets.count - beforeSecond, 3)
        XCTAssertFalse(second.isEmpty)
    }

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Song \(id)",
            artist: artist,
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

private actor CursorMusicService: MusicService {
    private(set) var mixOffsets: [Int] = []
    private(set) var mixPages: [Int] = []
    private(set) var recommendationTargets: [String?] = []
    private var recommendationSerial = 0

    func configure(userAgent: String?) async {}

    func profile(accessToken: String) async throws -> UserProfile {
        throw APIError.invalidResponse
    }

    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        throw APIError.invalidResponse
    }

    func recommendations(
        accessToken: String,
        targetAudio: String?,
        shuffle: Bool
    ) async throws -> [Track] {
        recommendationTargets.append(targetAudio)
        guard targetAudio != nil else { return [] }
        recommendationSerial += 1
        let base = 1_000 + recommendationSerial * 10
        return [
            makeTrack(id: base + 1, artist: "Similar"),
            makeTrack(id: base + 2, artist: "Similar")
        ]
    }

    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        track
    }

    func mixes(accessToken: String) async throws -> [MusicMix] {
        [.common]
    }

    func catalogSnapshot(accessToken: String) async throws -> VKCatalogSnapshot {
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
        mixOffsets.append(startingOffset)
        mixPages.append(pages)
        return [makeTrack(id: startingOffset + 1, artist: mix.title)]
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

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Song \(id)",
            artist: artist,
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

/// Deterministic RNG for ranker tests (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class PinnedMixStoreTests: XCTestCase {
    func testPinPersistsPerAccount() {
        let suite = "PinnedMixStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PinnedMixStore(defaults: defaults)
        store.configure(accountID: 42)
        let mix = MusicMix.common
        let track = Track(
            trackID: 9,
            ownerID: 1,
            title: "Pinned",
            artist: "Artist",
            duration: 120,
            streamURL: nil,
            artworkURL: nil
        )
        store.pin(mix: mix, tracks: [track], currentIndex: 0, elapsed: 12)
        XCTAssertEqual(store.pin?.mixID, mix.id)
        XCTAssertEqual(store.pin?.tracks.first?.id, track.id)

        let restored = PinnedMixStore(defaults: defaults)
        restored.configure(accountID: 42)
        XCTAssertEqual(restored.pin?.tracks.first?.title, "Pinned")

        restored.configure(accountID: 7)
        XCTAssertNil(restored.pin)
    }
}
