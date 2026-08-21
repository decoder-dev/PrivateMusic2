import XCTest
@testable import PrivateMusic

final class SelenaWavePolicyTests: XCTestCase {
    func testBanditWeightsFavorFavoritesAndDiscover() {
        let favorite = SelenaWavePolicy.banditWeights(diversity: .favorite)
        let discover = SelenaWavePolicy.banditWeights(diversity: .discover)
        XCTAssertGreaterThan(favorite.familiarity, discover.familiarity)
        XCTAssertGreaterThan(discover.novelty, favorite.novelty)
        XCTAssertEqual(
            favorite.familiarity + favorite.novelty,
            1,
            accuracy: 0.0001
        )
    }

    func testPreferMoodBoostsMatchingTitles() {
        let calm = makeTrack(id: 1, title: "Спокойный вечер", artist: "A")
        let other = makeTrack(id: 2, title: "Party Fire", artist: "B")
        let ordered = SelenaWavePolicy.preferMood(
            [other, calm],
            mood: .calm
        )
        XCTAssertEqual(ordered.map(\.id), [calm.id, other.id])
    }

    func testDedupeRepeatsDropsFingerprintAndRecentIDs() {
        let first = makeTrack(id: 1, title: "Song", artist: "Artist")
        let duplicate = makeTrack(id: 2, title: "Song", artist: "Artist")
        let recent = makeTrack(id: 3, title: "Other", artist: "C")
        let fresh = makeTrack(id: 4, title: "Fresh", artist: "D")
        let result = SelenaWavePolicy.dedupeRepeats(
            [first, duplicate, recent, fresh],
            recentTrackIDs: [recent.id]
        )
        XCTAssertEqual(result.map(\.id), [first.id, fresh.id])
    }

    func testImpliedFamiliarityMapsDiversity() {
        XCTAssertEqual(
            SelenaWavePolicy.impliedFamiliarity(diversity: .favorite),
            .hits
        )
        XCTAssertEqual(
            SelenaWavePolicy.impliedFamiliarity(diversity: .discover),
            .obscure
        )
        XCTAssertEqual(
            SelenaWavePolicy.impliedFamiliarity(diversity: .default),
            .any
        )
    }

    func testInstrumentalLanguageHeuristic() {
        let instrumental = makeTrack(
            id: 1,
            title: "Theme (Instrumental)",
            artist: "Score"
        )
        let vocal = makeTrack(id: 2, title: "Love Song", artist: "Singer")
        XCTAssertTrue(MixQueueFilter.looksInstrumental(instrumental))
        XCTAssertFalse(MixQueueFilter.looksInstrumental(vocal))
        XCTAssertTrue(
            MixQueueFilter.matchesLanguage(instrumental, preference: .instrumental)
        )
        XCTAssertFalse(
            MixQueueFilter.matchesLanguage(vocal, preference: .instrumental)
        )
    }

    func testDiscoverComposeLeansSimilar() {
        let seeds = [makeTrack(id: 1, title: "Seed", artist: "S")]
        let personal = [
            makeTrack(id: 2, title: "P1", artist: "P"),
            makeTrack(id: 3, title: "P2", artist: "P")
        ]
        let similar = [
            makeTrack(id: 4, title: "N1", artist: "N"),
            makeTrack(id: 5, title: "N2", artist: "N"),
            makeTrack(id: 6, title: "N3", artist: "N")
        ]
        let discover = SelenaRecommendationComposer.compose(
            seedTracks: seeds,
            personalRecommendations: personal,
            similarRecommendations: similar,
            diversity: .discover,
            limit: 5
        ).tracks
        let similarCount = discover.filter { $0.artist == "N" }.count
        let personalCount = discover.filter { $0.artist == "P" }.count
        XCTAssertGreaterThanOrEqual(similarCount, personalCount)
    }

    func testArtistCooldownDropsHotArtistsUnlessPoolWouldEmpty() {
        let hot = makeTrack(id: 1, title: "Hot", artist: "Same")
        let cool = makeTrack(id: 2, title: "Cool", artist: "Other")
        let filtered = SelenaWavePolicy.applyingArtistCooldown(
            [hot, cool],
            recentArtistKeys: Array(
                repeating: MixFeedbackPolicy.normalized("Same"),
                count: 3
            )
        )
        XCTAssertEqual(filtered.map(\.id), [cool.id])

        let onlyHot = SelenaWavePolicy.applyingArtistCooldown(
            [hot],
            recentArtistKeys: [MixFeedbackPolicy.normalized("Same")]
        )
        XCTAssertEqual(onlyHot.map(\.id), [hot.id])
    }

    private func makeTrack(
        id: Int,
        title: String,
        artist: String
    ) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: title,
            artist: artist,
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
