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
        // Named match first. Folding "looks like a vibe shelf" into the
        // same condition made every vibe shelf answer every mood, so
        // «Спокойно» picked «Энергичный драйв» purely because it came
        // first in the catalog — the bug this whole policy exists to kill.
        if let named = mixes.first(where: { matchesMarkers($0, mood: mood) }) {
            return .mix(named)
        }
        // A generic vibe shelf still beats the ordinary station when
        // nothing names this mood, but it can never outrank a real match.
        if let vibe = mixes.first(where: isVibeShelf) {
            return .mix(vibe)
        }
        return fallback(in: mixes)
    }

    /// A shelf names a mood when its own title, the catalog section it came
    /// from, or its subtitle carries one of that mood's markers — the same
    /// three places Home's vibe chips looked at.
    static func matchesMarkers(
        _ mix: MusicMix,
        mood: MixMoodPreference
    ) -> Bool {
        guard mood != .any else { return true }
        let shelfTitle = mix.sectionTitle ?? mix.title
        return MixQueueFilter.shelfMatchesMood(shelfTitle, mood: mood)
            || MixQueueFilter.shelfMatchesMood(mix.subtitle, mood: mood)
            || MixQueueFilter.shelfMatchesMood(mix.title, mood: mood)
    }

    /// Reads as a mood shelf without naming one in particular.
    static func isVibeShelf(_ mix: MusicMix) -> Bool {
        MixSeedRadio.looksLikeVibeShelf(mix.sectionTitle ?? mix.title)
    }

    private static func fallback(in mixes: [MusicMix]) -> MixMoodLaunch {
        if let personal = mixes.first(where: { $0.id == MusicMix.common.id }) {
            return .mix(personal)
        }
        return .myMusic
    }
}
