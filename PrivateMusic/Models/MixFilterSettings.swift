import Foundation

/// Client-side VK-mix style filters. Official mood/language/familiarity
/// knobs are not documented on `getStreamMixAudios`, so we apply them to
/// the already-fetched candidate pool (and map mood chips to vibe shelves).
enum MixMoodPreference: String, CaseIterable, Identifiable, Sendable {
    case any
    case energetic
    case calm
    case sad
    case joyful
    case love

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: L10n.text("Любое")
        case .energetic: L10n.text("Активно")
        case .calm: L10n.text("Спокойно")
        case .sad: L10n.text("Грустно")
        case .joyful: L10n.text("Радостно")
        case .love: L10n.text("Любовь")
        }
    }

    var vibeMarkers: [String] {
        switch self {
        case .any: return []
        case .energetic: return ["актив", "энерг", "спорт", "party", "work", "drive"]
        case .calm: return ["спокой", "relax", "вечер", "тиш", "sleep", "calm"]
        case .sad: return ["груст", "sad", "melanch", "дожд"]
        case .joyful: return ["радост", "happy", "весел", "good vib"]
        case .love: return ["любов", "love", "романт"]
        }
    }
}

enum MixLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case any
    case russian
    case foreign

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: L10n.text("Любой язык")
        case .russian: L10n.text("Русский")
        case .foreign: L10n.text("Иностранный")
        }
    }
}

enum MixFamiliarityPreference: String, CaseIterable, Identifiable, Sendable {
    case any
    case hits
    case obscure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: L10n.text("Любая узнаваемость")
        case .hits: L10n.text("Больше хитов")
        case .obscure: L10n.text("Больше находок")
        }
    }
}

enum MixQueueFilter {
    static func apply(
        _ tracks: [Track],
        language: MixLanguagePreference,
        familiarity: MixFamiliarityPreference,
        historyArtists: Set<String>
    ) -> [Track] {
        let normalizedHistory = Set(
            historyArtists.map(MixFeedbackPolicy.normalized)
        )
        return tracks.filter { track in
            matchesLanguage(track, preference: language)
                && matchesFamiliarity(
                    track,
                    preference: familiarity,
                    historyArtists: normalizedHistory
                )
        }
    }

    static func matchesLanguage(
        _ track: Track,
        preference: MixLanguagePreference
    ) -> Bool {
        switch preference {
        case .any:
            return true
        case .russian:
            return containsCyrillic(track.title) || containsCyrillic(track.artist)
        case .foreign:
            return !containsCyrillic(track.title) && !containsCyrillic(track.artist)
        }
    }

    static func matchesFamiliarity(
        _ track: Track,
        preference: MixFamiliarityPreference,
        historyArtists: Set<String>
    ) -> Bool {
        let artist = MixFeedbackPolicy.normalized(track.artist)
        let known = !artist.isEmpty && historyArtists.contains(artist)
        switch preference {
        case .any: return true
        case .hits: return known
        case .obscure: return !known
        }
    }

    static func shelfMatchesMood(
        _ title: String,
        mood: MixMoodPreference
    ) -> Bool {
        guard mood != .any else { return true }
        let blob = title
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "ru_RU")
            )
            .lowercased()
        return mood.vibeMarkers.contains { blob.contains($0) }
    }

    private static func containsCyrillic(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x0400...0x04FF).contains($0.value)
        }
    }
}
