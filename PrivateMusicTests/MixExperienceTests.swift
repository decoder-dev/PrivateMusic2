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
