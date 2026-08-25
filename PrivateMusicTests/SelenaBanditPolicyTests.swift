import XCTest
@testable import PrivateMusic

final class SelenaBanditPolicyTests: XCTestCase {
    private func track(
        _ id: Int,
        artist: String,
        title: String = "Track"
    ) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: title,
            artist: artist,
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }

    private func queue(_ artists: [String]) -> [Track] {
        artists.enumerated().map { index, artist in
            track(index + 1, artist: artist)
        }
    }

    private func artists(_ tracks: [Track]) -> [String] {
        tracks.map(\.artist)
    }

    private func key(_ artist: String) -> String {
        MixFeedbackPolicy.normalized(artist)
    }

    /// The closest any artist comes to appearing twice. `Int.max` when
    /// nobody repeats at all.
    private func minimumGap(_ tracks: [Track]) -> Int {
        var lastSeen: [String: Int] = [:]
        var gap = Int.max
        for (index, track) in tracks.enumerated() {
            let artistKey = key(track.artist)
            if let previous = lastSeen[artistKey] {
                gap = min(gap, index - previous)
            }
            lastSeen[artistKey] = index
        }
        return gap
    }

    /// How many times two neighbours are by the same artist.
    private func adjacentRepeats(_ tracks: [Track]) -> Int {
        zip(tracks, tracks.dropFirst()).filter { lhs, rhs in
            !key(lhs.artist).isEmpty && key(lhs.artist) == key(rhs.artist)
        }.count
    }

    private func rerank(
        _ tracks: [Track],
        affinity: [String: Double] = [:],
        exposure: SelenaExposure = SelenaExposure(),
        banned: Set<String> = []
    ) -> [Track] {
        SelenaBanditPolicy.rerank(
            tracks,
            affinityByArtistKey: affinity,
            exposure: exposure,
            bannedArtists: banned
        )
    }

    // MARK: - Bans

    /// "Не нравится" has to mean the artist stops playing. The queue is
    /// normally filtered before it gets here, but a listener can ban an
    /// artist while a queue is cached, and a demotion would still put them
    /// on a few tracks later.
    func testABannedArtistIsRemovedRatherThanDemoted() {
        let result = rerank(
            queue(["Banned", "Kept", "Banned", "Other"]),
            banned: [key("Banned")]
        )

        XCTAssertFalse(artists(result).contains("Banned"))
        XCTAssertEqual(Set(artists(result)), ["Kept", "Other"])
    }

    func testBanningEveryArtistLeavesAnEmptyQueue() {
        XCTAssertTrue(
            rerank(queue(["Banned", "Banned"]), banned: [key("Banned")])
                .isEmpty
        )
    }

    /// A track with no artist cannot match a ban key, and dropping it would
    /// quietly lose playable music.
    func testATrackWithNoArtistSurvives() {
        XCTAssertEqual(
            rerank(queue(["", "Kept"]), banned: ["anything"]).count,
            2
        )
    }

    // MARK: - Familiarity

    /// Affinity grows with every confirmed play, so it is squashed rather
    /// than scaled against the queue: a queue of unknown artists must not
    /// promote one of them to "favourite" just by being the best of a bad
    /// lot.
    func testFamiliaritySaturatesInsteadOfGrowingWithoutBound() {
        XCTAssertEqual(SelenaBanditPolicy.familiarity(affinity: 0), 0)
        XCTAssertEqual(
            SelenaBanditPolicy.familiarity(
                affinity: SelenaBanditPolicy.affinityMidpoint
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertLessThan(
            SelenaBanditPolicy.familiarity(affinity: 1_000),
            1
        )
        XCTAssertGreaterThan(
            SelenaBanditPolicy.familiarity(affinity: 8),
            SelenaBanditPolicy.familiarity(affinity: 4)
        )
    }

    /// The mix and Home's "What's Next" must not disagree about who counts
    /// as a favourite.
    func testTheHalfwayPointIsTheBarHomeAlreadyUses() {
        XCTAssertEqual(
            SelenaBanditPolicy.affinityMidpoint,
            ArtistAffinityPolicy.qualifyingScore
        )
    }

    func testAFavouriteIsLiftedAboveAnUnknownArtist() {
        let result = rerank(
            queue(["Unknown", "Favourite"]),
            affinity: [key("Favourite"): 4]
        )

        XCTAssertEqual(artists(result).first, "Favourite")
    }

    // MARK: - Novelty

    func testNoveltyFallsAsAnArtistFillsTheQueue() {
        XCTAssertEqual(SelenaBanditPolicy.novelty(impressions: 0), 1)
        XCTAssertGreaterThan(
            SelenaBanditPolicy.novelty(impressions: 1),
            SelenaBanditPolicy.novelty(impressions: 9)
        )
        XCTAssertGreaterThan(SelenaBanditPolicy.novelty(impressions: 99), 0)
    }

    /// Two artists the listener likes equally: the one this session has
    /// already leaned on goes second.
    func testExposureSeparatesTwoEquallyLikedArtists() {
        let result = rerank(
            queue(["Heard", "Fresh"]),
            affinity: [key("Heard"): 2, key("Fresh"): 2],
            exposure: SelenaExposure(
                impressionsByArtist: [key("Heard"): 9],
                totalImpressions: 9
            )
        )

        XCTAssertEqual(artists(result).first, "Fresh")
    }

    /// Familiarity is weighted to win, or a personal mix stops being
    /// personal — an artist with real evidence behind them outranks an
    /// unknown one even when the unknown has never been shown.
    func testFamiliarityOutweighsNoveltyForAClearFavourite() {
        let result = rerank(
            queue(["NeverShown", "Favourite"]),
            affinity: [key("Favourite"): 6],
            exposure: SelenaExposure(
                impressionsByArtist: [key("Favourite"): 3],
                totalImpressions: 3
            )
        )

        XCTAssertEqual(artists(result).first, "Favourite")
        XCTAssertEqual(
            SelenaBanditPolicy.familiarityWeight
                + SelenaBanditPolicy.noveltyWeight,
            1,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            SelenaBanditPolicy.familiarityWeight,
            SelenaBanditPolicy.noveltyWeight
        )
    }

    func testMoodBoostCanOutrankEqualAffinityCandidates() {
        let calm = track(1, artist: "A", title: "Спокойный вечер")
        let other = track(2, artist: "B", title: "Party Fire")
        let result = SelenaBanditPolicy.rerank(
            [other, calm],
            affinityByArtistKey: [:],
            exposure: SelenaExposure(),
            bannedArtists: [],
            moodScoresByTrackID: [
                calm.id: SelenaWavePolicy.moodScore(calm, mood: .calm),
                other.id: 0
            ],
            moodWeight: SelenaBanditPolicy.moodWeight
        )
        XCTAssertEqual(result.first?.id, calm.id)
    }

    func testJoinedCreditUsesComponentAffinity() {
        let collab = track(1, artist: "Alpha, Beta")
        let stranger = track(2, artist: "Gamma")
        let result = rerank(
            [stranger, collab],
            affinity: [key("Alpha"): 6],
            exposure: SelenaExposure()
        )
        XCTAssertEqual(result.first?.artist, "Alpha, Beta")
    }

    // MARK: - Spacing

    /// The point of the whole thing: favourites recur, but never back to
    /// back.
    func testTheSameArtistIsKeptApartAcrossTheQueue() {
        let source = queue(
            Array(repeating: "Ann", count: 6)
                + Array(repeating: "Bob", count: 5)
                + Array(repeating: "Cid", count: 4)
                + Array(repeating: "Dee", count: 3)
                + Array(repeating: "Eve", count: 2)
                + ["Fox"]
        )

        let result = rerank(
            source,
            affinity: [key("Ann"): 6, key("Bob"): 3, key("Cid"): 1]
        )

        XCTAssertGreaterThanOrEqual(
            minimumGap(result),
            SelenaBanditPolicy.artistSpacing
        )
    }

    /// Once the minority artists run out, a naive greedy dumps everything
    /// left by the top-scoring artist in one block at the end. Falling back
    /// to whoever has been away longest keeps the tail alternating instead.
    func testTheTailDoesNotCollapseIntoOneArtist() {
        let source = queue(
            Array(repeating: "Ann", count: 6)
                + Array(repeating: "Bob", count: 5)
                + ["Cid", "Dee", "Eve"]
        )

        let result = rerank(source, affinity: [key("Ann"): 6])

        XCTAssertEqual(adjacentRepeats(result), 0)
    }

    func testNoTrackIsLostOrDuplicated() {
        let source = queue(
            Array(repeating: "Ann", count: 6)
                + Array(repeating: "Bob", count: 5)
                + ["Cid", "Dee", "Eve"]
        )

        let result = rerank(source, affinity: [key("Ann"): 6])

        XCTAssertEqual(result.count, source.count)
        XCTAssertEqual(Set(result.map(\.id)), Set(source.map(\.id)))
    }

    /// Spacing is a constraint on the order, not a filter. A queue with
    /// only one artist left comes back whole and clumped rather than
    /// short — dropping music to look varied is the worse trade.
    func testAQueueOfOneArtistComesBackWhole() {
        let source = queue(["Same", "Same", "Same"])

        XCTAssertEqual(
            rerank(source).map(\.id),
            source.map(\.id)
        )
    }

    /// Tracks with no artist are not one big act called "nobody" and must
    /// not be spaced apart from each other.
    func testBlankArtistsAreNotSpacedAgainstEachOther() {
        let source = queue(["", "", "", ""])

        XCTAssertEqual(rerank(source).map(\.id), source.map(\.id))
    }

    // MARK: - Determinism and cold start

    /// A listener with no history yet gets the queue the source built,
    /// not a reshuffle — there is no evidence to reorder it by.
    func testColdStartKeepsTheIncomingOrder() {
        XCTAssertEqual(
            artists(rerank(queue(["A", "B", "C", "D"]))),
            ["A", "B", "C", "D"]
        )
    }

    func testTheSameQueueAndEvidenceAlwaysGiveTheSameOrder() {
        let source = queue(["Ann", "Bob", "Ann", "Cid", "Ann", "Bob"])
        let affinity = [key("Ann"): 5.0, key("Bob"): 2.0]

        XCTAssertEqual(
            rerank(source, affinity: affinity).map(\.id),
            rerank(source, affinity: affinity).map(\.id)
        )
    }

    func testShortQueuesComeBackUnchanged() {
        XCTAssertTrue(rerank([]).isEmpty)

        let single = queue(["A"])
        XCTAssertEqual(rerank(single).map(\.id), single.map(\.id))
    }

    // MARK: - Exposure bookkeeping

    func testRecordingCountsEveryTrackAndIgnoresBlankArtists() {
        var exposure = SelenaExposure()
        exposure.record(queue(["A", "A", "B", "  "]))

        XCTAssertEqual(exposure.impressions(forArtistKey: key("A")), 2)
        XCTAssertEqual(exposure.impressions(forArtistKey: key("B")), 1)
        // Blank artists are skipped on both sides, so the total stays the
        // sum of the per-artist counts.
        XCTAssertEqual(exposure.totalImpressions, 3)
    }

    func testResetClearsTheSession() {
        var exposure = SelenaExposure()
        exposure.record(queue(["A"]))
        exposure.reset()

        XCTAssertEqual(exposure.totalImpressions, 0)
        XCTAssertEqual(exposure.impressions(forArtistKey: key("A")), 0)
    }
}
