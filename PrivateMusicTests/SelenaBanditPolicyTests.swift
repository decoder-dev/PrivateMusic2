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

    private func artists(_ tracks: [Track]) -> [String] {
        tracks.map(\.artist)
    }

    // MARK: - Bans

    /// "Не нравится" has to mean the artist stops playing. The queue is
    /// normally filtered before it gets here, but a listener can ban an
    /// artist after the queue was cached, and a demotion would still put
    /// them on a few tracks later.
    func testABannedArtistIsRemovedRatherThanDemoted() {
        let queue = [
            track(1, artist: "Banned"),
            track(2, artist: "Kept"),
            track(3, artist: "Banned"),
            track(4, artist: "Other")
        ]

        let result = SelenaBanditPolicy.rerank(
            queue,
            exposure: SelenaExposure(),
            bannedArtists: [MixFeedbackPolicy.normalized("Banned")]
        )

        XCTAssertFalse(artists(result).contains("Banned"))
        XCTAssertEqual(Set(artists(result)), ["Kept", "Other"])
    }

    func testBanningEveryArtistLeavesAnEmptyQueueRatherThanASurprise() {
        let queue = [track(1, artist: "Banned"), track(2, artist: "Banned")]

        let result = SelenaBanditPolicy.rerank(
            queue,
            exposure: SelenaExposure(),
            bannedArtists: [MixFeedbackPolicy.normalized("Banned")]
        )

        XCTAssertTrue(result.isEmpty)
    }

    /// A track with no artist at all cannot match a ban key, and dropping
    /// it would quietly lose playable music.
    func testATrackWithNoArtistSurvives() {
        let queue = [track(1, artist: ""), track(2, artist: "Kept")]

        let result = SelenaBanditPolicy.rerank(
            queue,
            exposure: SelenaExposure(),
            bannedArtists: ["anything"]
        )

        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Exploration

    func testTheBonusFallsAsAnArtistIsUsed() {
        let fresh = SelenaBanditPolicy.explorationBonus(
            pulls: 0,
            totalPulls: 20
        )
        let used = SelenaBanditPolicy.explorationBonus(
            pulls: 8,
            totalPulls: 20
        )
        XCTAssertGreaterThan(fresh, used)
        XCTAssertGreaterThan(used, 0)
    }

    func testAnUnheardArtistIsLiftedAboveAHeavilyPlayedOne() {
        let exposure = SelenaExposure(
            pullsByArtist: [MixFeedbackPolicy.normalized("Heard"): 30],
            totalPulls: 30
        )
        let queue = [
            track(1, artist: "Heard"),
            track(2, artist: "Unheard")
        ]

        let result = SelenaBanditPolicy.rerank(
            queue,
            exposure: exposure,
            bannedArtists: []
        )

        XCTAssertEqual(artists(result).first, "Unheard")
    }

    /// The incoming order already reflects the listener's taste, so a
    /// queue where nobody has been heard yet must come back untouched
    /// rather than shuffled — and the same input must always give the
    /// same output.
    func testEqualExposureKeepsTheIncomingOrder() {
        let queue = [
            track(1, artist: "A"),
            track(2, artist: "B"),
            track(3, artist: "C"),
            track(4, artist: "D")
        ]

        let result = SelenaBanditPolicy.rerank(
            queue,
            exposure: SelenaExposure(),
            bannedArtists: []
        )

        XCTAssertEqual(artists(result), ["A", "B", "C", "D"])
        XCTAssertEqual(
            result.map(\.id),
            SelenaBanditPolicy.rerank(
                queue,
                exposure: SelenaExposure(),
                bannedArtists: []
            ).map(\.id)
        )
    }

    // MARK: - Runs

    func testThreeTracksByOneArtistDoNotStayInARow() {
        let queue = [
            track(1, artist: "Same"),
            track(2, artist: "Same"),
            track(3, artist: "Same"),
            track(4, artist: "Other"),
            track(5, artist: "Third")
        ]

        let result = SelenaBanditPolicy.breakingUpRuns(queue)
        let names = artists(result)
        let runs = zip(names, names.dropFirst()).filter { $0 == $1 }.count

        XCTAssertLessThan(runs, 2)
        XCTAssertEqual(Set(result.map(\.id)), Set(queue.map(\.id)))
    }

    /// The pass thins runs, it does not invent variety: a queue that only
    /// holds one artist keeps its run. Losing tracks to look diverse
    /// would be the worse trade.
    func testAQueueWithNothingToSwapInKeepsItsRun() {
        let queue = [
            track(1, artist: "Same"),
            track(2, artist: "Same"),
            track(3, artist: "Same")
        ]

        XCTAssertEqual(
            SelenaBanditPolicy.breakingUpRuns(queue).map(\.id),
            queue.map(\.id)
        )
    }

    /// Tracks with no artist must not be treated as one big run of
    /// "nobody" and shuffled against each other.
    func testBlankArtistsAreNotTreatedAsARun() {
        let queue = [
            track(1, artist: ""),
            track(2, artist: ""),
            track(3, artist: "Other")
        ]

        XCTAssertEqual(
            SelenaBanditPolicy.breakingUpRuns(queue).map(\.id),
            queue.map(\.id)
        )
    }

    // MARK: - Exposure bookkeeping

    func testRecordingCountsEveryTrackAndIgnoresBlankArtists() {
        var exposure = SelenaExposure()
        exposure.record([
            track(1, artist: "A"),
            track(2, artist: "A"),
            track(3, artist: "B"),
            track(4, artist: "  ")
        ])

        XCTAssertEqual(
            exposure.pulls(forArtistKey: MixFeedbackPolicy.normalized("A")),
            2
        )
        XCTAssertEqual(
            exposure.pulls(forArtistKey: MixFeedbackPolicy.normalized("B")),
            1
        )
        // Blank artists are skipped on both sides, so the total stays the
        // sum of the per-artist counts — which is what the bonus divides.
        XCTAssertEqual(exposure.totalPulls, 3)
    }

    func testResetClearsTheSession() {
        var exposure = SelenaExposure()
        exposure.record([track(1, artist: "A")])
        exposure.reset()

        XCTAssertEqual(exposure.totalPulls, 0)
        XCTAssertEqual(
            exposure.pulls(forArtistKey: MixFeedbackPolicy.normalized("A")),
            0
        )
    }

    // MARK: - Degenerate input

    func testShortQueuesComeBackUnchanged() {
        XCTAssertTrue(
            SelenaBanditPolicy.rerank(
                [],
                exposure: SelenaExposure(),
                bannedArtists: []
            ).isEmpty
        )

        let single = [track(1, artist: "A")]
        XCTAssertEqual(
            SelenaBanditPolicy.rerank(
                single,
                exposure: SelenaExposure(),
                bannedArtists: []
            ).map(\.id),
            single.map(\.id)
        )
    }
}
