import SwiftUI

/// VK sometimes hands back a multi-artist credit as one comma-joined
/// string ("SKWLKR, Lastfragm, ..."). One line of hero text can carry one
/// credit — the lead artist survives, with the rest folded into a short
/// count instead of the raw string running on past where it reads.
enum ArtistCreditDisplay {
    /// Splits VK's comma-joined multi-artist credit into individual names.
    /// The one place this happens — `readable`, `summarize` and
    /// `ArtistAffinityPolicy` all read a credit through this rather than
    /// re-splitting on "," themselves, so a featuring credit resolves to
    /// the same artists everywhere it is scored or displayed.
    static func components(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The Hero needs the artist's real name in full — never the bubble's
    /// "+N" shorthand. VK's raw multi-artist credit is comma-joined; this
    /// reads like a byline ("SKWLKR & Lastfragment") instead of a
    /// database field. Used only for the Hero headline; bubbles keep the
    /// compact `summarize(_:)` policy below.
    static func readable(_ raw: String) -> String {
        let parts = components(raw)
        guard let first = parts.first else { return raw }
        guard parts.count > 1 else { return first }
        let allButLast = parts.dropLast().joined(separator: ", ")
        guard let last = parts.last else { return allButLast }
        return "\(allButLast) & \(last)"
    }

    static func summarize(_ raw: String) -> String {
        let parts = components(raw)
        // No comma at all (or nothing usable behind it) — pass the
        // original through rather than an empty string.
        guard let first = parts.first else { return raw }
        // A trailing or doubled comma from upstream data must not turn one
        // real artist into "Name +1"; it still deserves the trimmed name.
        guard parts.count > 1 else { return first }
        return L10n.format(
            "home_stage.artist_plus_d0",
            first,
            parts.count - 1
        )
    }
}

/// An artist the listener has actually played, carried with enough to
/// start them for real. The name alone is a display string; hanging
/// playback off it is how the artist bubble ended up launching a generic
/// library mix that had nothing to do with whoever was tapped.
struct HomeStageArtist: Hashable, Sendable {
    let name: String
    /// The most recent track we hold by them. Used as the radio seed when
    /// VK's artist lookup does not resolve, so the fallback is still about
    /// this artist rather than about everything.
    let seed: Track?
}

/// One bubble on the Home rail: a musical context you can enter.
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

    /// The palette role, so the rail reads as a legend: a listener learns
    /// "green is a mood" instead of re-reading every label.
    var role: BubbleRole {
        switch self {
        case .station: .station
        case .vibe: .mood
        case .artist: .artist
        case .mix: .mix
        }
    }

    /// What tapping this does, in the listener's words.
    var actionHint: String {
        switch self {
        case .station: L10n.text("home_stage.action.station")
        case .vibe: L10n.text("home_stage.action.vibe")
        case .artist: L10n.text("home_stage.action.artist")
        case .mix: L10n.text("home_stage.action.mix")
        }
    }

    var symbol: String {
        switch self {
        case .station: "sparkles"
        case .vibe: "waveform"
        case .artist: "music.mic"
        case .mix: "square.stack"
        }
    }
}

struct HomeStageContext: Identifiable, Hashable, Sendable {
    let id: String
    let kind: HomeStageContextKind
    let name: String
    /// Prominence, and therefore size. Derived from what the context *is*,
    /// never from its position — sizing by index made re-ordering the data
    /// silently resize the rail.
    let priority: BubblePriority
    /// Curator or artist photo when VK exposes one; a monogram covers the
    /// gap so a missing photo never leaves a hole.
    let avatarURL: URL?
    let mixID: String?
    let mood: MixMoodPreference?
    let artist: HomeStageArtist?

    var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// A bubble is one circle with one short label — a raw multi-artist
    /// credit read as broken data.
    var displayName: String { ArtistCreditDisplay.summarize(name) }

    /// One sentence carrying the noun *and* what tapping does. VoiceOver
    /// saying "Исполнитель, Owar1" leaves the listener guessing whether it
    /// opens a page or starts playing.
    var accessibilityLabel: String {
        "\(kind.kicker) \(displayName). \(kind.actionHint)"
    }
}

/// Builds the rail out of what the app already knows. Free of views and
/// stores, so ordering, de-duplication and the cap are tested directly.
enum HomeStageContextBuilder {
    static let limit = 6

    static func resolveRailContexts(
        hasCurrentTrack: Bool,
        queueSource: QueueSource?,
        currentArtist: String?,
        mixes: [MusicMix],
        historyEntries: [any HomeStagePlayable],
        selectedMood: MixMoodPreference,
        stationTitle: String
    ) -> [HomeStageContext] {
        let occupancy = HomeNextStepPolicy.occupancy(
            hasCurrentTrack: hasCurrentTrack,
            queueSource: queueSource,
            currentArtist: currentArtist,
            mixes: mixes
        )
        return build(
            mixes: mixes,
            recentArtists: recentArtists(from: historyEntries),
            selectedMood: selectedMood,
            stationTitle: stationTitle,
            omitStation: shouldOmitStation(
                hasCurrentTrack: hasCurrentTrack,
                queueSource: queueSource,
                mixes: mixes
            ),
            occupiedArtistKeys: occupancy.occupiedArtistKeys
        )
    }

    static func build(
        mixes: [MusicMix],
        recentArtists: [HomeStageArtist],
        selectedMood: MixMoodPreference,
        stationTitle: String,
        omitStation: Bool = false,
        occupiedArtistKeys: Set<String> = []
    ) -> [HomeStageContext] {
        var contexts: [HomeStageContext] = []
        var takenNames = Set<String>()

        func append(
            id: String,
            kind: HomeStageContextKind,
            name: String,
            rank: Int = 0,
            avatarURL: URL? = nil,
            mixID: String? = nil,
            mood: MixMoodPreference? = nil,
            artist: HomeStageArtist? = nil
        ) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, takenNames.insert(key).inserted else { return }
            contexts.append(
                HomeStageContext(
                    id: id,
                    kind: kind,
                    name: trimmed,
                    priority: BubblePriorityPolicy.priority(
                        for: kind,
                        rank: rank
                    ),
                    avatarURL: avatarURL,
                    mixID: mixID,
                    mood: mood,
                    artist: artist
                )
            )
        }

        if !omitStation {
            // The station always leads when Hero is not already offering it.
            // Idle Hero's "Включить" *is* the station, so the rail must not
            // repeat that same action as its first tile.
            append(
                id: "station",
                kind: .station,
                name: stationTitle
            )
        }
        // Mix catalog still arrives so Home doesn't grow a second fetch;
        // the rail itself no longer renders mix tiles.
        _ = mixes

        // Only the mood the listener actually picked. All five would push
        // everything else off the rail.
        if selectedMood != .any {
            append(
                id: "vibe-\(selectedMood.rawValue)",
                kind: .vibe,
                name: L10n.format(
                    "home_stage.vibe_launch_d0",
                    selectedMood.title
                ),
                mood: selectedMood
            )
        }

        for (rank, artist) in recentArtists.enumerated() {
            guard !isOccupiedArtist(artist.name, keys: occupiedArtistKeys)
            else { continue }
            append(
                id: "artist-\(artist.name.lowercased())",
                kind: .artist,
                name: artist.name,
                rank: rank,
                avatarURL: artist.seed?.artworkURL,
                artist: artist
            )
        }

        // Catalog mixes are Explore / What's Next. The rail is session
        // control: station, vibe, and recent artists — not another mix
        // shelf sitting under the hero.
        return Array(contexts.prefix(limit))
    }

    /// The Hero already names this artist; the rail must not offer the same
    /// «В стиле» shortcut underneath it.
    static func isOccupiedArtist(
        _ name: String,
        keys: Set<String>
    ) -> Bool {
        guard !keys.isEmpty else { return false }
        for component in ArtistCreditDisplay.components(name) {
            let key = MixFeedbackPolicy.normalized(component)
            if keys.contains(key) { return true }
        }
        return false
    }

    /// Personal Selena is already the session when idle (Hero CTA) or when
    /// that mix is what's playing — the rail must not repeat it.
    static func shouldOmitStation(
        hasCurrentTrack: Bool,
        queueSource: QueueSource?,
        mixes: [MusicMix]
    ) -> Bool {
        HomeNextStepPolicy.occupancy(
            hasCurrentTrack: hasCurrentTrack,
            queueSource: queueSource,
            currentArtist: nil,
            mixes: mixes
        ).occupiedKinds.contains(.personalStation)
    }

    /// The artists behind the most recent plays, newest first, without
    /// repeats — an evening spent looping one album should not fill the
    /// rail with the same face.
    static func recentArtists(
        from entries: [any HomeStagePlayable],
        limit: Int = 3
    ) -> [HomeStageArtist] {
        var seen = Set<String>()
        var artists: [HomeStageArtist] = []
        for entry in entries {
            let track = entry.stageTrack
            let name = track.artist
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  seen.insert(name.lowercased()).inserted else {
                continue
            }
            artists.append(HomeStageArtist(name: name, seed: track))
            if artists.count == limit { break }
        }
        return artists
    }
}

/// Lets the builder read history entries without importing the store.
protocol HomeStagePlayable {
    var stageTrack: Track { get }
}

extension ListeningHistoryEntry: HomeStagePlayable {
    var stageTrack: Track { track }
}

/// What the stage shows when nothing is playing. Kept as a value so "idle
/// shows one call to action and no disabled heart" is a test rather than a
/// reading of the view body.
struct HomeStagePresentation: Equatable {
    let showsHeart: Bool
    let showsTransportButton: Bool
    let showsCallToAction: Bool
    let chipIsProminent: Bool

    static func resolve(hasCurrentTrack: Bool) -> HomeStagePresentation {
        HomeStagePresentation(
            // Idle had a disabled heart, a play button and a big "Включить"
            // pill all at once — three controls for one action.
            showsHeart: hasCurrentTrack,
            showsTransportButton: hasCurrentTrack,
            showsCallToAction: !hasCurrentTrack,
            chipIsProminent: hasCurrentTrack
        )
    }
}

/// Prominence, decided by what a context *is*. The previous rule read
/// `priority(forPosition: contexts.count)`, which is exactly the
/// positional sizing the system is supposed to forbid: re-ordering the
/// data resized the rail and told the listener nothing.
enum BubblePriorityPolicy {
    static func priority(
        for kind: HomeStageContextKind,
        rank: Int = 0
    ) -> BubblePriority {
        switch kind {
        case .station:
            // The one context that always works, so it always leads.
            return .primary
        case .vibe:
            return .secondary
        case .artist:
            // The most recently played artist earns the larger circle;
            // the rest sit with the mixes.
            return rank == 0 ? .secondary : .tertiary
        case .mix:
            return .tertiary
        }
    }
}
