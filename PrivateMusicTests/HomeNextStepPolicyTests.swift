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

private func makeMix(
    _ id: String,
    title: String,
    subtitle: String = ""
) -> MusicMix {
    MusicMix(
        id: id,
        title: title,
        subtitle: subtitle,
        artworkURL: nil
    )
}

private func makeArtist(
    key: String,
    name: String,
    score: Double,
    reason: ArtistAffinityCandidate.Reason = .frequentRecently
) -> ArtistAffinityCandidate {
    ArtistAffinityCandidate(
        artistKey: key,
        displayName: name,
        score: score,
        evidenceTrackCount: 3,
        isLiked: reason == .likedAndPlayed,
        reason: reason,
        artworkURL: nil,
        seedTrackID: "seed-\(key)"
    )
}

private func request(
    affinity: [ArtistAffinityCandidate] = [],
    previouslyShownArtistKey: String? = nil,
    previouslyShownKey: String? = nil,
    mixes: [MusicMix] = [],
    selectedMood: MixMoodPreference = .any,
    occupancy: HomeNextStepOccupancy = .none,
    hasCurrentTrack: Bool? = nil,
    hasListeningHistory: Bool = true,
    hasRecommendations: Bool = true
) -> HomeNextStepRequest {
    HomeNextStepRequest(
        affinityCandidates: affinity,
        previouslyShownArtistKey: previouslyShownArtistKey,
        previouslyShownKey: previouslyShownKey,
        mixes: mixes,
        selectedMood: selectedMood,
        occupancy: occupancy,
        hasCurrentTrack: hasCurrentTrack ?? (occupancy != .idle),
        hasListeningHistory: hasListeningHistory,
        hasRecommendations: hasRecommendations
    )
}

@MainActor
final class HomeNextStepPolicyTests: XCTestCase {
    func testStrongArtistAffinityBeatsAValidVKMix() {
        let winner = HomeNextStepPolicy.select(
            request(
                affinity: [makeArtist(key: "pokoleno", name: "Поколено", score: 2.4)],
                mixes: [makeMix("vk1", title: "Вечерний микс")],
                occupancy: .idle
            )
        )

        XCTAssertEqual(winner?.kind, .artistContinuation)
        XCTAssertEqual(winner?.artistKey, "pokoleno")
        XCTAssertEqual(winner?.titleArgument, "Поколено")
    }

    func testNoHistoryLetsAVKMixWin() {
        let winner = HomeNextStepPolicy.select(
            request(
                mixes: [makeMix("vk1", title: "Для начала")],
                occupancy: .idle,
                hasListeningHistory: false,
                hasRecommendations: false
            )
        )

        XCTAssertEqual(winner?.kind, .vkMix)
        XCTAssertEqual(winner?.mixID, "vk1")
    }

    func testStrongSelenaContinuationWinsWhenPlayingSomethingElse() {
        let winner = HomeNextStepPolicy.select(
            request(
                occupancy: HomeNextStepOccupancy(
                    occupiedKinds: [],
                    occupiedMixIDs: [],
                    occupiedArtistKeys: ["other"]
                ),
                hasListeningHistory: true,
                hasRecommendations: true
            )
        )

        XCTAssertEqual(winner?.kind, .personalStation)
    }

    func testSuppressedArtistIsExcludedEvenWhenScoreIsHighest() {
        let winner = HomeNextStepPolicy.select(
            request(
                affinity: [
                    makeArtist(key: "hidden", name: "Hidden", score: 3.0)
                ],
                mixes: [makeMix("vk1", title: "Микс")],
                occupancy: HomeNextStepOccupancy(
                    occupiedKinds: [.personalStation],
                    occupiedMixIDs: [MusicMix.common.id],
                    occupiedArtistKeys: ["hidden"]
                )
            )
        )

        XCTAssertEqual(winner?.kind, .vkMix)
        XCTAssertNotEqual(winner?.artistKey, "hidden")
    }

    func testBannedArtistNeverEntersTheAffinityPool() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = (1...3).map { index in
            ListeningHistoryEntry(
                track: makeTrack(id: index, artist: "Hidden"),
                playedAt: now.addingTimeInterval(TimeInterval(-index * 3600))
            )
        }
        let affinity = ArtistAffinityPolicy.candidates(
            history: history,
            isLiked: { _ in false },
            bannedArtistKeys: ["hidden"],
            now: now
        )
        XCTAssertTrue(affinity.isEmpty)

        let winner = HomeNextStepPolicy.select(
            request(
                affinity: affinity,
                mixes: [makeMix("vk1", title: "Микс")],
                occupancy: .idle,
                hasListeningHistory: true
            )
        )
        XCTAssertEqual(winner?.kind, .vkMix)
    }

    func testAllWeakPersonalizedCandidatesOmitTheSlot() {
        let winner = HomeNextStepPolicy.select(
            request(
                occupancy: .idle,
                hasListeningHistory: false,
                hasRecommendations: false
            )
        )
        XCTAssertNil(winner)
    }

    func testSameStateStaysStableAcrossRepeatedSelects() {
        let input = request(
            affinity: [makeArtist(key: "rive", name: "RIVE", score: 2.1)],
            mixes: [makeMix("vk1", title: "Микс")],
            occupancy: .idle
        )
        let first = HomeNextStepPolicy.select(input)
        let second = HomeNextStepPolicy.select(
            request(
                affinity: input.affinityCandidates,
                previouslyShownArtistKey: "rive",
                previouslyShownKey: first?.stabilityKey,
                mixes: input.mixes,
                occupancy: .idle
            )
        )
        XCTAssertEqual(first?.stabilityKey, second?.stabilityKey)
        XCTAssertEqual(first?.kind, .artistContinuation)
    }

    func testHysteresisKeepsTheShownCandidateWhenTheChallengerIsOnlySlightlyBetter() {
        let stickyVK = HomeNextStepPolicy.select(
            request(
                mixes: [makeMix("vk1", title: "Микс")],
                occupancy: .idle,
                hasListeningHistory: false,
                hasRecommendations: false
            )
        )
        XCTAssertEqual(stickyVK?.kind, .vkMix)

        let next = HomeNextStepPolicy.select(
            request(
                affinity: [makeArtist(key: "rive", name: "RIVE", score: 1.70)],
                previouslyShownKey: stickyVK?.stabilityKey,
                mixes: [makeMix("vk1", title: "Микс")],
                occupancy: .idle,
                hasListeningHistory: false,
                hasRecommendations: false
            )
        )
        XCTAssertEqual(next?.kind, .vkMix)
    }

    /// The retention bar sits below the qualifying bar so a card already on
    /// screen survives a dip instead of vanishing. Selecting against the
    /// qualifying bar a second time made that band dead: an artist whose
    /// score decayed just under the entry bar was dropped even though
    /// nothing else qualified, and Home lost the section entirely.
    func testAShownCandidateSurvivesADipIntoTheRetentionBand() {
        let dipped = makeArtist(
            key: "rive",
            name: "RIVE",
            score: (HomeNextStepPolicy.qualifyingConfidence
                + HomeNextStepPolicy.retentionConfidence) / 2
        )
        XCTAssertLessThan(
            dipped.score,
            HomeNextStepPolicy.qualifyingConfidence
        )
        XCTAssertGreaterThanOrEqual(
            dipped.score,
            HomeNextStepPolicy.retentionConfidence
        )

        let held = HomeNextStepPolicy.select(
            request(
                affinity: [dipped],
                previouslyShownArtistKey: "rive",
                previouslyShownKey: "artist:rive",
                occupancy: .idle,
                hasListeningHistory: true,
                hasRecommendations: false
            )
        )

        XCTAssertEqual(held?.stabilityKey, "artist:rive")
    }

    /// Retention is only for a card that was actually on screen — the same
    /// score must not be enough to appear in the first place.
    func testTheRetentionBandDoesNotLetANewCandidateIn() {
        let weak = makeArtist(
            key: "rive",
            name: "RIVE",
            score: (HomeNextStepPolicy.qualifyingConfidence
                + HomeNextStepPolicy.retentionConfidence) / 2
        )

        let fresh = HomeNextStepPolicy.select(
            request(
                affinity: [weak],
                occupancy: .idle,
                hasListeningHistory: true,
                hasRecommendations: false
            )
        )

        XCTAssertNotEqual(fresh?.stabilityKey, "artist:rive")
    }

    func testIdleOccupancyDoesNotDuplicateThePersonalStation() {
        let occupancy = HomeNextStepPolicy.occupancy(
            hasCurrentTrack: false,
            queueSource: nil,
            currentArtist: nil,
            mixes: [makeMix(MusicMix.common.id, title: "Селена")]
        )
        XCTAssertTrue(occupancy.occupiedKinds.contains(.personalStation))

        let winner = HomeNextStepPolicy.select(
            request(
                occupancy: occupancy,
                hasListeningHistory: true,
                hasRecommendations: true
            )
        )
        XCTAssertNotEqual(winner?.kind, .personalStation)
    }

    func testPlayingTheCurrentArtistOccupiesThatArtistCandidate() {
        let occupancy = HomeNextStepPolicy.occupancy(
            hasCurrentTrack: true,
            queueSource: .mix(id: "pokoleno", title: "Поколено radio"),
            currentArtist: "Поколено",
            mixes: [makeMix("vk1", title: "Микс")]
        )
        XCTAssertTrue(
            occupancy.occupiedArtistKeys.contains(
                MixFeedbackPolicy.normalized("Поколено")
            )
        )

        let winner = HomeNextStepPolicy.select(
            request(
                affinity: [
                    makeArtist(
                        key: MixFeedbackPolicy.normalized("Поколено"),
                        name: "Поколено",
                        score: 3.0
                    )
                ],
                mixes: [makeMix("vk1", title: "Микс")],
                occupancy: occupancy
            )
        )
        XCTAssertNotEqual(winner?.artistKey, MixFeedbackPolicy.normalized("Поколено"))
    }

    func testPlayingAVKMixOccupiesThatMix() {
        let mix = makeMix("vk1", title: "Вечерний микс")
        let occupancy = HomeNextStepPolicy.occupancy(
            hasCurrentTrack: true,
            queueSource: .mix(id: "evening", title: "Вечерний микс"),
            currentArtist: "Someone",
            mixes: [mix]
        )
        XCTAssertTrue(occupancy.occupiedMixIDs.contains("vk1"))

        let winner = HomeNextStepPolicy.select(
            request(
                mixes: [mix, makeMix("vk2", title: "Другой")],
                occupancy: occupancy,
                hasListeningHistory: false,
                hasRecommendations: false
            )
        )
        XCTAssertEqual(winner?.mixID, "vk2")
    }

    func testVibeContinuationCanWinWhenTheSessionHasAClearMood() {
        let energetic = makeMix("energy", title: "Энергичный драйв")
        let winner = HomeNextStepPolicy.select(
            request(
                mixes: [energetic],
                selectedMood: .energetic,
                occupancy: HomeNextStepOccupancy(
                    occupiedKinds: [],
                    occupiedMixIDs: [],
                    occupiedArtistKeys: []
                ),
                hasListeningHistory: true,
                hasRecommendations: false
            )
        )
        XCTAssertEqual(winner?.kind, .vibeContinuation)
        XCTAssertEqual(winner?.mixID, "energy")
    }
}
