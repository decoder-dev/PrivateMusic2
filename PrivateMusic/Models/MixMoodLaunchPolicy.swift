import Foundation

/// What starting a mood should actually play. Home's vibe chips resolved
/// this inline, so the Home stage's mood bubble had no way to reuse it and
/// fell back to the personal station — the mood changed a setting and
/// nothing else. One resolver now serves both, and it is pure, so "does
/// the mood reach the queue" is a test rather than a claim.
enum MixMoodLaunch: Equatable {
    /// Start this mix. Mood-matching shelf, or the personal station.
    case mix(MusicMix)
    /// Nothing in the catalog matches — blend the listener's own library.
    case myMusic
}

enum MixMoodLaunchPolicy {
    static func resolve(
        mood: MixMoodPreference,
        in mixes: [MusicMix]
    ) -> MixMoodLaunch {
        guard mood != .any else { return fallback(in: mixes) }
        if let match = mixes.first(where: { matches($0, mood: mood) }) {
            return .mix(match)
        }
        return fallback(in: mixes)
    }

    /// A shelf counts for a mood when its own title, the catalog section it
    /// came from, or its subtitle carries one of the mood's markers — the
    /// same three places Home's vibe chips looked at.
    static func matches(_ mix: MusicMix, mood: MixMoodPreference) -> Bool {
        guard mood != .any else { return true }
        let shelfTitle = mix.sectionTitle ?? mix.title
        return MixQueueFilter.shelfMatchesMood(shelfTitle, mood: mood)
            || MixQueueFilter.shelfMatchesMood(mix.subtitle, mood: mood)
            || MixQueueFilter.shelfMatchesMood(mix.title, mood: mood)
            || MixSeedRadio.looksLikeVibeShelf(shelfTitle)
    }

    private static func fallback(in mixes: [MusicMix]) -> MixMoodLaunch {
        if let personal = mixes.first(where: { $0.id == MusicMix.common.id }) {
            return .mix(personal)
        }
        return .myMusic
    }
}
