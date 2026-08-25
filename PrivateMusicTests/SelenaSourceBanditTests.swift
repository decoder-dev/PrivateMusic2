import XCTest
@testable import PrivateMusic

final class SelenaSourceBanditTests: XCTestCase {
    func testComposeBiasNudgeFollowsRewardedArm() {
        var bandit = SelenaSourceBandit()
        let base = SelenaWavePolicy.composeBias(diversity: .default)

        for _ in 0..<6 {
            bandit.reward(.similar, success: true)
            bandit.reward(.personal, success: false)
        }

        let nudged = bandit.composeBias(diversity: .default)
        XCTAssertGreaterThanOrEqual(nudged.similar, base.similar)
        XCTAssertGreaterThanOrEqual(nudged.similar, nudged.personal)
    }

    func testRewardFromListenUpdatesBias() {
        var bandit = SelenaSourceBandit()
        for _ in 0..<8 {
            bandit.reward(.similar, success: true)
            bandit.reward(.personal, success: false)
        }
        let bias = bandit.composeBias(diversity: .default)
        XCTAssertGreaterThanOrEqual(bias.similar, bias.personal)
    }

    func testComposeTagsSources() {
        let seed = track(1, "Seed")
        let personal = [track(2, "P"), track(3, "P")]
        let similar = [track(4, "S"), track(5, "S")]
        let composed = SelenaRecommendationComposer.compose(
            seedTracks: [seed],
            personalRecommendations: personal,
            similarRecommendations: similar,
            limit: 5
        )
        XCTAssertEqual(composed.sources["1_2"], .personal)
        XCTAssertEqual(composed.sources["1_4"], .similar)
        XCTAssertEqual(composed.tracks.count, composed.sources.count)
    }

    func testComposeInsertsSeedsOnPlacementCadenceNotResultCount() {
        let seeds = (0..<6).map { track(10 + $0, "Seed\($0)") }
        let personal = (0..<20).map { track(100 + $0, "P\($0)") }
        let similar = (0..<20).map { track(200 + $0, "S\($0)") }
        let composed = SelenaRecommendationComposer.compose(
            seedTracks: seeds,
            personalRecommendations: personal,
            similarRecommendations: similar,
            diversity: .default,
            limit: 16
        )
        let seedCount = composed.tracks.filter {
            composed.sources[$0.id] == .seed
        }.count
        // seedEvery=4 with steady personal+similar fills → more than one seed.
        XCTAssertGreaterThanOrEqual(seedCount, 2)
    }

    func testArtistCapBlocksSameArtistBeyondLimit() {
        let personal = (0..<8).map { track(100 + $0, "Same") }
        let similar = (0..<8).map { track(200 + $0, "Other\($0)") }
        let composed = SelenaRecommendationComposer.compose(
            seedTracks: [],
            personalRecommendations: personal,
            similarRecommendations: similar,
            artistCap: 2,
            limit: 10
        )
        let sameCount = composed.tracks.filter { $0.artist == "Same" }.count
        XCTAssertLessThanOrEqual(sameCount, 2)
        XCTAssertGreaterThan(composed.tracks.count, sameCount)
    }

    private func track(_ id: Int, _ artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "T\(id)",
            artist: artist,
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
