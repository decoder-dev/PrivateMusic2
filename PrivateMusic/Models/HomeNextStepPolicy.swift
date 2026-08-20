import Foundation

/// The single recommendation Home is allowed to show. Every personalization
/// source competes for this slot; none of them get their own shelf.
enum HomeNextStepKind: String, Equatable, Hashable, Sendable {
    case artistContinuation
    case personalStation
    case vibeContinuation
    case vkMix
}

enum HomeNextStepAction: Equatable, Sendable {
    case artist(name: String, artistKey: String)
    case personalStation
    case mood(MixMoodPreference)
    case mix(id: String)
}

struct HomeNextStepCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let kind: HomeNextStepKind
    let titleKey: String
    let titleArgument: String?
    let subtitleKey: String
    let actionKey: String
    let artworkURL: URL?
    let confidence: Double
    let stabilityKey: String
    let sourceIsSelena: Bool
    let mixID: String?
    let artistKey: String?
    let action: HomeNextStepAction
}

/// What the Hero / current session already represents, so What's Next
/// cannot repeat the same action underneath it.
struct HomeNextStepOccupancy: Equatable, Sendable {
    var occupiedKinds: Set<HomeNextStepKind>
    var occupiedMixIDs: Set<String>
    var occupiedArtistKeys: Set<String>

    static let none = HomeNextStepOccupancy(
        occupiedKinds: [],
        occupiedMixIDs: [],
        occupiedArtistKeys: []
    )

    /// Idle Hero's call to action *is* the personal station. That action
    /// must not reappear as What's Next.
    static let idle = HomeNextStepOccupancy(
        occupiedKinds: [.personalStation],
        occupiedMixIDs: [MusicMix.common.id],
        occupiedArtistKeys: []
    )

    func excludes(_ candidate: HomeNextStepCandidate) -> Bool {
        if occupiedKinds.contains(candidate.kind) { return true }
        if let mixID = candidate.mixID, occupiedMixIDs.contains(mixID) {
            return true
        }
        if let artistKey = candidate.artistKey,
           occupiedArtistKeys.contains(artistKey) {
            return true
        }
        return false
    }
}

struct HomeNextStepRequest: Equatable, Sendable {
    var affinityCandidates: [ArtistAffinityCandidate]
    var previouslyShownArtistKey: String?
    var previouslyShownKey: String?
    var mixes: [MusicMix]
    var selectedMood: MixMoodPreference
    var occupancy: HomeNextStepOccupancy
    var hasCurrentTrack: Bool
    var hasListeningHistory: Bool
    var hasRecommendations: Bool
}

/// Inputs that can change the Home "What's Next" winner. Catalog caches
/// the resolved candidate behind this key so scrolling does not re-run the
/// full picker on every body pass.
struct HomeNextStepRefreshKey: Equatable, Sendable {
    var currentTrackID: String?
    var queueSource: QueueSource?
    var currentArtist: String?
    var selectedMood: MixMoodPreference
    var historyHeadTrackIDs: [String]
    var mixIDs: [String]
    var recommendationsEmpty: Bool
    var previouslyShownArtistKey: String?
    var previouslyShownKey: String?
    var bannedArtistKeys: [String]
    var bannedTrackIDs: [String]
    var librarySignatures: [String]
}

enum HomeNextStepPolicy {
    static let qualifyingConfidence = 1.0
    static let retentionConfidence = 0.85
    static let hysteresis = 0.25

    static let vkMixStarterConfidence = 1.55
    static let vkMixBaseConfidence = 1.05
    static let personalStationStrongConfidence = 1.45
    static let personalStationBaseConfidence = 1.18
    static let vibePlayingConfidence = 1.52
    static let vibeIdleConfidence = 0.95

    static func occupancy(
        hasCurrentTrack: Bool,
        queueSource: QueueSource?,
        currentArtist: String?,
        mixes: [MusicMix]
    ) -> HomeNextStepOccupancy {
        guard hasCurrentTrack else { return .idle }

        var mixIDs = Set<String>()
        var kinds = Set<HomeNextStepKind>()
        var artistKeys = Set<String>()

        for name in ArtistCreditDisplay.components(currentArtist ?? "") {
            let key = MixFeedbackPolicy.normalized(name)
            if !key.isEmpty { artistKeys.insert(key) }
        }

        if case let .mix(id, title) = queueSource {
            mixIDs.insert(id)
            if id == MusicMix.common.id {
                kinds.insert(.personalStation)
            }
            let trimmed = title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let match = mixes.first(where: {
                $0.id == id || $0.title.compare(
                    trimmed,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                mixIDs.insert(match.id)
                if match.id == MusicMix.common.id {
                    kinds.insert(.personalStation)
                }
            }
            let normalizedTitle = MixFeedbackPolicy.normalized(trimmed)
            let commonTitle = MixFeedbackPolicy.normalized(
                MusicMix.common.title
            )
            if !normalizedTitle.isEmpty, normalizedTitle == commonTitle {
                kinds.insert(.personalStation)
                mixIDs.insert(MusicMix.common.id)
            }
        }

        return HomeNextStepOccupancy(
            occupiedKinds: kinds,
            occupiedMixIDs: mixIDs,
            occupiedArtistKeys: artistKeys
        )
    }

    static func select(
        _ request: HomeNextStepRequest
    ) -> HomeNextStepCandidate? {
        let visible = deduplicate(generate(request))
            .filter { !request.occupancy.excludes($0) }
            .filter { $0.confidence >= retentionConfidence }
        let qualified = visible.filter {
            $0.confidence >= qualifyingConfidence
        }

        if let previous = request.previouslyShownKey,
           let sticky = visible.first(
               where: { $0.stabilityKey == previous }
           ) {
            if let challenger = qualified.max(by: Self.isOrderedBefore),
               challenger.stabilityKey != sticky.stabilityKey,
               challenger.confidence >= sticky.confidence + hysteresis {
                return challenger
            }
            // Holding the slot down to `retentionConfidence` is the whole
            // point of having a second, lower bar — `visible` has already
            // applied it. Re-testing against `qualifyingConfidence` here
            // made the retention band dead: a card that dipped just under
            // the entry bar was dropped for a weaker one, or for nothing
            // at all, which is the flicker the hysteresis exists to damp.
            return sticky
        }

        return qualified.max(by: Self.isOrderedBefore)
    }

    // MARK: - Generation

    private static func generate(
        _ request: HomeNextStepRequest
    ) -> [HomeNextStepCandidate] {
        var candidates: [HomeNextStepCandidate] = []

        if let artist = ArtistAffinityPolicy.selectDynamicArtist(
            from: request.affinityCandidates,
            previouslyShownKey: request.previouslyShownArtistKey
        ) {
            candidates.append(artistCandidate(artist))
        }

        let vkMixes = HomeVKMixesPolicy.candidates(from: request.mixes)
            .filter { $0.id != MusicMix.common.id }
        for (index, mix) in vkMixes.prefix(3).enumerated() {
            let base = request.hasListeningHistory
                ? vkMixBaseConfidence
                : vkMixStarterConfidence
            candidates.append(
                vkMixCandidate(mix, confidence: base - Double(index) * 0.08)
            )
        }

        if request.hasCurrentTrack {
            let confidence: Double
            if request.hasRecommendations && request.hasListeningHistory {
                confidence = personalStationStrongConfidence
            } else if request.hasRecommendations
                || request.hasListeningHistory {
                confidence = personalStationBaseConfidence
            } else {
                confidence = 0.7
            }
            if confidence >= retentionConfidence {
                candidates.append(personalStationCandidate(confidence))
            }
        }

        if request.selectedMood != .any {
            switch MixMoodLaunchPolicy.resolve(
                mood: request.selectedMood,
                in: request.mixes
            ) {
            case let .mix(mix) where mix.id != MusicMix.common.id:
                let confidence = request.hasCurrentTrack
                    ? vibePlayingConfidence
                    : vibeIdleConfidence
                candidates.append(
                    vibeCandidate(
                        mix: mix,
                        mood: request.selectedMood,
                        confidence: confidence
                    )
                )
            default:
                break
            }
        }

        return candidates
    }

    private static func deduplicate(
        _ candidates: [HomeNextStepCandidate]
    ) -> [HomeNextStepCandidate] {
        var byIdentity: [String: HomeNextStepCandidate] = [:]
        for candidate in candidates {
            let key = candidate.mixID.map { "mix:\($0)" }
                ?? candidate.artistKey.map { "artist:\($0)" }
                ?? candidate.kind.rawValue
            if let existing = byIdentity[key] {
                if candidate.confidence > existing.confidence {
                    byIdentity[key] = candidate
                }
            } else {
                byIdentity[key] = candidate
            }
        }
        return Array(byIdentity.values)
    }

    private static func isOrderedBefore(
        _ lhs: HomeNextStepCandidate,
        _ rhs: HomeNextStepCandidate
    ) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence < rhs.confidence
        }
        return lhs.stabilityKey > rhs.stabilityKey
    }

    private static func artistCandidate(
        _ artist: ArtistAffinityCandidate
    ) -> HomeNextStepCandidate {
        HomeNextStepCandidate(
            id: "artist-\(artist.artistKey)",
            kind: .artistContinuation,
            titleKey: "home_next.continue_with_0",
            titleArgument: artist.displayName,
            subtitleKey: subtitleKey(for: artist.reason),
            actionKey: "home_next.action.continue",
            artworkURL: artist.artworkURL,
            confidence: artist.score,
            stabilityKey: "artist:\(artist.artistKey)",
            sourceIsSelena: true,
            mixID: nil,
            artistKey: artist.artistKey,
            action: .artist(
                name: artist.displayName,
                artistKey: artist.artistKey
            )
        )
    }

    private static func vkMixCandidate(
        _ mix: MusicMix,
        confidence: Double
    ) -> HomeNextStepCandidate {
        HomeNextStepCandidate(
            id: "vk-\(mix.id)",
            kind: .vkMix,
            titleKey: "home_next.vk.title",
            titleArgument: mix.title,
            subtitleKey: "home_next.vk.subtitle",
            actionKey: "home_next.action.play",
            artworkURL: mix.artworkURL,
            confidence: confidence,
            stabilityKey: "vk:\(mix.id)",
            sourceIsSelena: false,
            mixID: mix.id,
            artistKey: nil,
            action: .mix(id: mix.id)
        )
    }

    private static func personalStationCandidate(
        _ confidence: Double
    ) -> HomeNextStepCandidate {
        HomeNextStepCandidate(
            id: "station-selena",
            kind: .personalStation,
            titleKey: "home_next.station.title",
            titleArgument: nil,
            subtitleKey: "home_next.station.subtitle",
            actionKey: "home_next.action.start",
            artworkURL: nil,
            confidence: confidence,
            stabilityKey: "station:selena",
            sourceIsSelena: true,
            mixID: MusicMix.common.id,
            artistKey: nil,
            action: .personalStation
        )
    }

    private static func vibeCandidate(
        mix: MusicMix,
        mood: MixMoodPreference,
        confidence: Double
    ) -> HomeNextStepCandidate {
        HomeNextStepCandidate(
            id: "vibe-\(mood.rawValue)",
            kind: .vibeContinuation,
            titleKey: "home_next.vibe.title",
            titleArgument: nil,
            subtitleKey: "home_next.vibe.subtitle",
            actionKey: "home_next.action.continue",
            artworkURL: mix.artworkURL,
            confidence: confidence,
            stabilityKey: "vibe:\(mood.rawValue):\(mix.id)",
            sourceIsSelena: false,
            mixID: mix.id,
            artistKey: nil,
            action: .mood(mood)
        )
    }

    private static func subtitleKey(
        for reason: ArtistAffinityCandidate.Reason
    ) -> String {
        switch reason {
        case .likedAndPlayed:
            return "home_next.reason.into_now"
        case .frequentRecently:
            return "home_next.reason.returning"
        case .multipleTracks:
            return "home_next.reason.recent"
        }
    }
}
