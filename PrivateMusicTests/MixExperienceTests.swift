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
    func testCloserToSeedPrefersSameArtist() {
        let seed = makeTrack(id: 1, artist: "Alpha")
        let same = makeTrack(id: 2, artist: "Alpha")
        let other = makeTrack(id: 3, artist: "Beta")
        let ranked = MixQueueRanker.rerank(
            queue: [seed, other, same],
            currentIndex: 0,
            seed: seed,
            mode: .closerToSeed
        )
        XCTAssertEqual(ranked.map(\.id), [seed.id, same.id, other.id])
    }

    func testMoreNovelPushesFamiliarArtistsDown() {
        let seed = makeTrack(id: 1, artist: "Alpha")
        let familiar = makeTrack(id: 2, artist: "Alpha")
        let novel = makeTrack(id: 3, artist: "Zeta")
        let ranked = MixQueueRanker.rerank(
            queue: [seed, familiar, novel],
            currentIndex: 0,
            seed: seed,
            mode: .moreNovel,
            historyArtists: ["Alpha"]
        )
        XCTAssertEqual(ranked.map(\.id), [seed.id, novel.id, familiar.id])
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
