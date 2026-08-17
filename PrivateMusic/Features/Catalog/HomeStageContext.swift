import SwiftUI

/// One bubble on the Home stage: a way back into listening that is not a
/// shelf card. Kinds are ordered by how strong a claim they have on the
/// rail — the personal station first, then moods, then whatever the
/// listener has actually been playing.
enum HomeStageContextKind: String, Hashable, Sendable {
    case station
    case vibe
    case artist
    case mix

    var kicker: String {
        switch self {
        case .station: L10n.text("home_stage.kind.station")
        case .vibe: L10n.text("home_stage.kind.vibe")
        case .artist: L10n.text("home_stage.kind.artist")
        case .mix: L10n.text("home_stage.kind.mix")
        }
    }

    /// Fixed per kind rather than sampled from artwork. The reference the
    /// design came from does the same: the bubbles are a legend, so a
    /// listener learns "green means a mood" instead of re-reading every
    /// label. Sampling would repaint them on every track change.
    var tint: Color {
        switch self {
        case .station: Color(red: 0.77, green: 0.33, blue: 0.17)
        case .vibe: Color(red: 0.18, green: 0.55, blue: 0.31)
        case .artist: Color(red: 0.72, green: 0.26, blue: 0.18)
        case .mix: Color(red: 0.49, green: 0.23, blue: 0.66)
        }
    }
}

struct HomeStageContext: Identifiable, Hashable, Sendable {
    let id: String
    let kind: HomeStageContextKind
    let name: String
    /// Curator or artist photo when VK exposes one; the bubble falls back
    /// to a monogram, so a missing photo never leaves a hole.
    let avatarURL: URL?
    /// Set when tapping the bubble should start a specific VK mix.
    let mixID: String?
    /// Set when tapping the bubble should apply a mood first.
    let mood: MixMoodPreference?

    var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

/// Builds the bubble rail out of what the app already knows. Kept free of
/// views and stores so the ordering and de-duplication rules can be tested
/// directly, the way the other `*Policy` types in this project are.
enum HomeStageContextBuilder {
    static let limit = 6

    static func build(
        mixes: [MusicMix],
        recentArtists: [String],
        selectedMood: MixMoodPreference,
        stationTitle: String
    ) -> [HomeStageContext] {
        var contexts: [HomeStageContext] = []
        var takenNames = Set<String>()

        func append(_ context: HomeStageContext) {
            let key = context.name.lowercased()
            guard !key.isEmpty, takenNames.insert(key).inserted else { return }
            contexts.append(context)
        }

        // The personal station always leads: it is the one context that is
        // available even with an empty catalog and no history.
        append(
            HomeStageContext(
                id: "station",
                kind: .station,
                name: stationTitle,
                avatarURL: nil,
                mixID: nil,
                mood: nil
            )
        )

        // The mood the listener actually picked, if any — showing all five
        // would push everything else off the rail.
        if selectedMood != .any {
            append(
                HomeStageContext(
                    id: "vibe-\(selectedMood.rawValue)",
                    kind: .vibe,
                    name: selectedMood.title,
                    avatarURL: nil,
                    mixID: nil,
                    mood: selectedMood
                )
            )
        }

        for artist in recentArtists {
            let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            append(
                HomeStageContext(
                    id: "artist-\(trimmed.lowercased())",
                    kind: .artist,
                    name: trimmed,
                    avatarURL: nil,
                    mixID: nil,
                    mood: nil
                )
            )
        }

        for mix in mixes {
            let title = mix.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            append(
                HomeStageContext(
                    id: "mix-\(mix.id)",
                    kind: .mix,
                    name: title,
                    avatarURL: mix.curator?.photoURL,
                    mixID: mix.id,
                    mood: nil
                )
            )
        }

        return Array(contexts.prefix(limit))
    }

    /// The artists behind the most recent plays, most recent first and
    /// without repeats — someone who looped one album all evening should
    /// not get six identical bubbles.
    static func recentArtists(
        from entries: [some HomeStagePlayable],
        limit: Int = 3
    ) -> [String] {
        var seen = Set<String>()
        var artists: [String] = []
        for entry in entries {
            let artist = entry.stageArtist
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty,
                  seen.insert(artist.lowercased()).inserted else {
                continue
            }
            artists.append(artist)
            if artists.count == limit { break }
        }
        return artists
    }
}

/// Lets the builder read history entries without importing the store.
protocol HomeStagePlayable {
    var stageArtist: String { get }
}

extension ListeningHistoryEntry: HomeStagePlayable {
    var stageArtist: String { track.artist }
}
