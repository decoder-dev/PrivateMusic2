import Foundation

/// How far back listening history is consulted for mix taste signals.
/// Named once so familiarity and ranking cannot silently diverge to
/// unrelated magic numbers again.
enum MixListeningHistoryWindow {
    /// Artists treated as "known" for hits / discoveries.
    static let familiarity = 80
    /// Artists fed into radio reranking and rationale copy.
    static let ranking = 40
}

/// Result of applying language / familiarity filters to a candidate pool.
struct MixFilterOutcome: Equatable, Sendable {
    let tracks: [Track]
    /// True when every candidate was rejected and the caller kept the
    /// pre-filter pool so the queue would not go empty.
    let didRelax: Bool
}

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
        case .any: L10n.text("any")
        case .energetic: L10n.text("energetic")
        case .calm: L10n.text("calm")
        case .sad: L10n.text("sad")
        case .joyful: L10n.text("joyful")
        case .love: L10n.text("love")
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
        case .any: L10n.text("any_language")
        case .russian: L10n.text("russian")
        case .foreign: L10n.text("foreign")
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
        case .any: L10n.text("any_familiarity")
        case .hits: L10n.text("more_hits")
        case .obscure: L10n.text("more_discoveries")
        }
    }
}

enum MixQueueFilter {
    /// The app folds Russian text two different ways on purpose, and this
    /// is the strict one:
    ///
    /// - Forgiving (`й` → `и`, `ё` → `е`): `pm_text_fold_utf8` behind
    ///   `NativeTextSearch`, `pm_text_normalize_identity` behind
    ///   `MixQueueRanker`, and `MixFeedbackPolicy.normalized` for ban keys.
    ///   Someone typing "мои" should find "мой", and an artist should match
    ///   however VK spelled them.
    /// - Strict (`й` kept, only `ё` → `е`): here. Mood markers are a curated
    ///   word list, and collapsing `й` makes them match text that has
    ///   nothing to do with the mood.
    private static func normalizeMoodText(_ value: String) -> String {
        // Canonicalize decomposed sequences (e.g. "и" + combining breve → "й")
        // so we can do stable substring matching for Cyrillic markers.
        let canonical = value.precomposedStringWithCanonicalMapping
        let ruLocale = Locale(identifier: "ru_RU")

        // `ё` should match `е` (we don't use `diacriticInsensitive` because
        // it can treat `й`'s breve as a diacritic and turn it into `и`).
        return canonical
            .replacingOccurrences(
                of: "ё",
                with: "е",
                options: [.caseInsensitive]
            )
            .lowercased(with: ruLocale)
    }

    static func shelfMoodMatchScore(
        _ title: String,
        mood: MixMoodPreference
    ) -> Int {
        guard mood != .any else { return 0 }
        let blob = normalizeMoodText(title)
        return mood.vibeMarkers.reduce(into: 0) { score, marker in
            let normalizedMarker = normalizeMoodText(marker)
            if textContainsMarker(blob, marker: normalizedMarker) {
                score += 1
            }
        }
    }

    /// Stem-style substring for Cyrillic; Latin uses a word start so
    /// "hit" cannot light up inside "white", while longer stems like
    /// "melanch" still reach "melancholy". Tokens of three letters or
    /// fewer require a full word boundary.
    static func textContainsMarker(_ haystack: String, marker: String) -> Bool {
        guard !marker.isEmpty else { return false }
        let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLatinToken(trimmed) {
            return matchesLatinMarker(haystack, token: trimmed)
        }
        return haystack.contains(trimmed)
    }

    private static func isLatinToken(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) && scalar.isASCII
        }
    }

    private static func matchesLatinMarker(_ haystack: String, token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        // Short Latin tokens are too ambiguous as prefixes ("hit" ⊂ "white"
        // is filtered by `\b…\b`; "top" must not match "stop").
        let pattern = token.count <= 3
            ? "\\b\(escaped)\\b"
            : "\\b\(escaped)"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    static func apply(
        _ tracks: [Track],
        language: MixLanguagePreference,
        familiarity: MixFamiliarityPreference,
        historyArtists: Set<String>
    ) -> [Track] {
        applyStrict(
            tracks,
            language: language,
            familiarity: familiarity,
            historyArtists: historyArtists
        )
    }

    /// Language / familiarity only — never silently widens the pool.
    static func applyStrict(
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

    /// Seed / bootstrap path: keep something to play when filters empty
    /// the pool. Callers that care about the silent widen get `didRelax`.
    static func applyAllowingFallback(
        _ tracks: [Track],
        language: MixLanguagePreference,
        familiarity: MixFamiliarityPreference,
        historyArtists: Set<String>
    ) -> MixFilterOutcome {
        let filtered = applyStrict(
            tracks,
            language: language,
            familiarity: familiarity,
            historyArtists: historyArtists
        )
        if filtered.isEmpty, !tracks.isEmpty {
            return MixFilterOutcome(tracks: tracks, didRelax: true)
        }
        return MixFilterOutcome(tracks: filtered, didRelax: false)
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
        return shelfMoodMatchScore(title, mood: mood) > 0
    }

    private static func containsCyrillic(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x0400...0x04FF).contains($0.value)
        }
    }
}
