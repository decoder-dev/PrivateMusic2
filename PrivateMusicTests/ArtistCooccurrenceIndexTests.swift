import XCTest
@testable import PrivateMusic

final class ArtistCooccurrenceIndexTests: XCTestCase {
    func testNeighborsRankByCooccurrenceCount() {
        let history = [
            entry(artist: "A"),
            entry(artist: "B"),
            entry(artist: "A"),
            entry(artist: "B"),
            entry(artist: "C")
        ]
        let table = ArtistCooccurrenceIndex.build(history: history, window: 2)
        let keyA = MixFeedbackPolicy.normalized("A")
        let neighbors = ArtistCooccurrenceIndex.neighbors(
            of: keyA,
            in: table,
            limit: 4
        )
        XCTAssertEqual(
            neighbors.first,
            MixFeedbackPolicy.normalized("B")
        )
    }

    func testBoostSeedsPreferCooccurringArtists() {
        let history = [
            entry(artist: "Focus"),
            entry(artist: "Neighbor"),
            entry(artist: "Focus"),
            entry(artist: "Neighbor")
        ]
        let seeds = [
            track(id: 1, artist: "Other"),
            track(id: 2, artist: "Neighbor"),
            track(id: 3, artist: "Far")
        ]
        let boosted = ArtistCooccurrenceIndex.boostSeeds(
            seeds,
            history: history
        )
        XCTAssertEqual(boosted.first?.artist, "Neighbor")
    }

    private func entry(artist: String) -> ListeningHistoryEntry {
        ListeningHistoryEntry(
            track: track(id: Int.random(in: 1...10_000), artist: artist),
            playedAt: Date()
        )
    }

    private func track(id: Int, artist: String) -> Track {
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
