import XCTest
@testable import PrivateMusic

private func makeTrack(
    id: Int,
    title: String = "Track",
    artist: String
) -> Track {
    Track(
        trackID: id,
        ownerID: 1,
        title: title,
        artist: artist,
        duration: 180,
        streamURL: nil,
        artworkURL: nil,
        isHQ: false
    )
}

private func makeEntry(
    id: Int,
    artist: String,
    daysAgo: Double,
    now: Date
) -> ListeningHistoryEntry {
    ListeningHistoryEntry(
        track: makeTrack(id: id, artist: artist),
        playedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
    )
}

@MainActor
final class ArtistAffinityEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyHistoryProducesNoCandidates() {
        let candidates = ArtistAffinityPolicy.candidates(
            history: [],
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        )
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertNil(
            ArtistAffinityPolicy.selectDynamicArtist(
                from: candidates,
                previouslyShownKey: nil
            )
        )
    }

    /// One accidental replay of a single track is evidence of a song, not
    /// an artist — it must never surface a recommendation on its own.
    func testSingleTrackDoesNotSurfaceAnArtist() {
        let history = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 1, now: now)
        ]
        let candidates = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testMultipleDistinctTracksRaiseAffinityAboveTheQualifyingBar() {
        let history = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 1, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 2, now: now),
            makeEntry(id: 3, artist: "RIVE", daysAgo: 3, now: now)
        ]
        let candidates = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.displayName, "RIVE")
        XCTAssertEqual(candidates.first?.evidenceTrackCount, 3)
        XCTAssertGreaterThanOrEqual(
            candidates.first?.score ?? 0,
            ArtistAffinityPolicy.qualifyingScore
        )
    }

    func testLikeBoostsAffinityWithoutCompoundingPerLikedTrack() {
        let history = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 1, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 2, now: now)
        ]
        let unliked = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        ).first

        let liked = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { $0.trackID == 1 },
            bannedArtistKeys: [],
            now: now
        ).first

        XCTAssertNotNil(unliked)
        XCTAssertNotNil(liked)
        XCTAssertGreaterThan(liked?.score ?? 0, unliked?.score ?? .infinity)
        XCTAssertEqual(liked?.reason, .likedAndPlayed)
    }

    /// Interest decays — the same evidence, further in the past, must
    /// score lower than it would today.
    func testRecencyDecayLowersOlderEvidence() {
        let recent = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 1, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 2, now: now)
        ]
        // Far enough back to be measurably weaker than `recent` while
        // still clearing the retention floor on its own — this test is
        // about the decay curve, not the analysis-window cutoff.
        let old = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 8, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 9, now: now)
        ]
        let recentScore = ArtistAffinityPolicy.candidates(
            history: recent,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        ).first?.score ?? 0
        let oldScore = ArtistAffinityPolicy.candidates(
            history: old,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        ).first?.score ?? .infinity

        XCTAssertGreaterThan(recentScore, oldScore)
    }

    /// History outside the analysis window contributes nothing at all —
    /// old interest a listener has moved on from should not resurface.
    func testHistoryOutsideTheAnalysisWindowIsIgnored() {
        let history = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 45, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 50, now: now)
        ]
        let candidates = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSuppressedArtistNeverAppearsRegardlessOfEvidence() {
        let history = [
            makeEntry(id: 1, artist: "RIVE", daysAgo: 1, now: now),
            makeEntry(id: 2, artist: "RIVE", daysAgo: 2, now: now),
            makeEntry(id: 3, artist: "RIVE", daysAgo: 3, now: now)
        ]
        let candidates = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in true },
            bannedArtistKeys: [MixFeedbackPolicy.normalized("RIVE")],
            now: now
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    /// A multi-artist credit distributes evidence to each real artist
    /// rather than treating the joined string as one fake artist.
    func testMultiArtistTrackDistributesEvidenceToEachArtist() {
        let history = [
            makeEntry(id: 1, artist: "SKWLKR, Lastfragment", daysAgo: 1, now: now),
            makeEntry(id: 2, artist: "SKWLKR", daysAgo: 2, now: now)
        ]
        let candidates = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: [],
            now: now
        )
        let names = Set(candidates.map(\.displayName))
        XCTAssertTrue(names.contains("SKWLKR"))
        // Lastfragment only has one distinct track's worth of evidence —
        // below the minimum, so it should not qualify on its own.
        XCTAssertFalse(names.contains("Lastfragment"))
    }

    func testSelectDynamicArtistPrefersThePreviouslyShownArtistWhileItStillQualifies() {
        let candidates = [
            ArtistAffinityCandidate(
                artistKey: "a",
                displayName: "A",
                score: 2.0,
                evidenceTrackCount: 3,
                isLiked: false,
                reason: .multipleTracks,
                artworkURL: nil,
                seedTrackID: nil
            ),
            ArtistAffinityCandidate(
                artistKey: "b",
                displayName: "B",
                score: 1.0,
                evidenceTrackCount: 2,
                isLiked: false,
                reason: .multipleTracks,
                artworkURL: nil,
                seedTrackID: nil
            )
        ]

        // Without history, the top scorer wins.
        XCTAssertEqual(
            ArtistAffinityPolicy.selectDynamicArtist(
                from: candidates,
                previouslyShownKey: nil
            )?.artistKey,
            "a"
        )

        // "B" was already showing and still clears the retention floor —
        // it should not be swapped out just because "A" scores higher.
        XCTAssertEqual(
            ArtistAffinityPolicy.selectDynamicArtist(
                from: candidates,
                previouslyShownKey: "b"
            )?.artistKey,
            "b"
        )
    }
}
