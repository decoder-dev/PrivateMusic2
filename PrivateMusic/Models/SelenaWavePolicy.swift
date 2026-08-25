import Foundation

/// Diversity dial for Selena — mirrors Yandex Music «Моя волна» `diversity`
/// (`favorite` / `popular` / `discover` / `default`) without calling Yandex.
/// Catalog VK mixes keep the simpler familiarity chip instead.
enum SelenaDiversityPreference: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case favorite
    case popular
    case discover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: L10n.text("selena.diversity.default")
        case .favorite: L10n.text("selena.diversity.favorite")
        case .popular: L10n.text("selena.diversity.popular")
        case .discover: L10n.text("selena.diversity.discover")
        }
    }

    var chipTitle: String {
        switch self {
        case .default: L10n.text("selena.diversity.default_chip")
        case .favorite: L10n.text("selena.diversity.favorite_chip")
        case .popular: L10n.text("selena.diversity.popular_chip")
        case .discover: L10n.text("selena.diversity.discover_chip")
        }
    }

    var chipSymbol: String {
        switch self {
        case .default: "circle.grid.cross"
        case .favorite: "heart.fill"
        case .popular: "chart.bar.fill"
        case .discover: "sparkles"
        }
    }

    var caption: String {
        switch self {
        case .default: L10n.text("selena.diversity.default_caption")
        case .favorite: L10n.text("selena.diversity.favorite_caption")
        case .popular: L10n.text("selena.diversity.popular_caption")
        case .discover: L10n.text("selena.diversity.discover_caption")
        }
    }
}

/// How Selena shapes the personal station from wave dials — local stand-in
/// for Yandex rotor moodEnergy / diversity, applied on top of VK seeds.
enum SelenaWavePolicy {
    /// How many recent queue placements an artist stays ineligible for
    /// *candidate generation* — Yandex My Wave filters "played < ~25
    /// tracks ago" before ranking; in-queue spacing (3–4) alone only nudges.
    static let artistCooldownWindow = 25

    /// Drop tracks whose artist is still inside the session cooldown window.
    /// If every candidate would vanish, return the input unchanged — silence
    /// is worse than a repeat.
    static func applyingArtistCooldown(
        _ tracks: [Track],
        recentArtistKeys: [String],
        window: Int = artistCooldownWindow
    ) -> [Track] {
        guard !tracks.isEmpty, window > 0, !recentArtistKeys.isEmpty else {
            return tracks
        }
        let blocked = Set(recentArtistKeys.suffix(window))
        let filtered = tracks.filter { track in
            let key = MixFeedbackPolicy.normalized(track.artist)
            return key.isEmpty || !blocked.contains(key)
        }
        return filtered.isEmpty ? tracks : filtered
    }

    /// Seed the cooldown window from a newest-first list (listening history
    /// order). Walking oldest-first and then trimming the front kept the
    /// coldest artists and dropped the hottest — the opposite of Yandex's
    /// "played < ~25 tracks ago" rule.
    static func cooldownArtists(
        fromNewestFirst tracks: [Track],
        window: Int = artistCooldownWindow
    ) -> [String] {
        guard window > 0 else { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        keys.reserveCapacity(min(window, tracks.count))
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
            if keys.count >= window { break }
        }
        return keys
    }

    static func appendCooldownArtists(
        _ keys: inout [String],
        from tracks: [Track],
        window: Int = artistCooldownWindow
    ) {
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty else { continue }
            keys.append(key)
        }
        if keys.count > window {
            keys.removeFirst(keys.count - window)
        }
    }

    /// Bandit familiarity vs novelty mix. Sums to 1.
    static func banditWeights(
        diversity: SelenaDiversityPreference
    ) -> (familiarity: Double, novelty: Double) {
        switch diversity {
        case .default: return (0.65, 0.35)
        case .favorite: return (0.82, 0.18)
        case .popular: return (0.55, 0.45)
        case .discover: return (0.32, 0.68)
        }
    }

    static func artistSpacing(
        diversity: SelenaDiversityPreference
    ) -> Int {
        switch diversity {
        case .default: return SelenaBanditPolicy.artistSpacing
        case .favorite: return 2
        case .popular: return 3
        case .discover: return 4
        }
    }

    /// Soft moodEnergy sort (Yandex does not hard-cut the pool). Tracks that
    /// match vibe markers rise; unmatched stay, just lower.
    static func preferMood(
        _ tracks: [Track],
        mood: MixMoodPreference
    ) -> [Track] {
        guard mood != .any, tracks.count > 1 else { return tracks }
        return tracks.enumerated()
            .sorted { lhs, rhs in
                let left = moodScore(lhs.element, mood: mood)
                let right = moodScore(rhs.element, mood: mood)
                if left == right { return lhs.offset < rhs.offset }
                return left > right
            }
            .map(\.element)
    }

    static func moodScore(_ track: Track, mood: MixMoodPreference) -> Int {
        guard mood != .any else { return 0 }
        let blob = "\(track.title) \(track.artist)"
        return MixQueueFilter.shelfMoodMatchScore(blob, mood: mood)
    }

    /// Drop near-duplicates (same artist + folded title) and anything the
    /// listener already heard in the recent window — Yandex wave feedback
    /// keeps the session from looping the same cut.
    static func dedupeRepeats(
        _ tracks: [Track],
        recentTrackIDs: Set<String>,
        limit: Int = MixTrackRequestPolicy.queueLimit
    ) -> [Track] {
        var seenIDs = recentTrackIDs
        var seenFingerprints = Set<String>()
        var result: [Track] = []
        result.reserveCapacity(min(limit, tracks.count))
        for track in tracks {
            guard seenIDs.insert(track.id).inserted else { continue }
            let fingerprint = repeatFingerprint(track)
            if !fingerprint.isEmpty,
               !seenFingerprints.insert(fingerprint).inserted {
                continue
            }
            result.append(track)
            if result.count >= limit { break }
        }
        return result
    }

    static func repeatFingerprint(_ track: Track) -> String {
        let artist = MixFeedbackPolicy.normalized(track.artist)
        let title = MixFeedbackPolicy.normalized(track.title)
        guard !artist.isEmpty || !title.isEmpty else { return "" }
        return "\(artist)|\(title)"
    }

    /// Map diversity onto the older familiarity chip when Selena still
    /// consults MixQueueFilter for a hard pass.
    static func impliedFamiliarity(
        diversity: SelenaDiversityPreference
    ) -> MixFamiliarityPreference {
        switch diversity {
        case .default: return .any
        case .favorite: return .hits
        case .popular: return .any
        case .discover: return .obscure
        }
    }

    /// How aggressively `compose` leans on personal vs similar vs seeds.
    static func composeBias(
        diversity: SelenaDiversityPreference
    ) -> (personal: Int, similar: Int, seedEvery: Int) {
        switch diversity {
        case .default: return (1, 1, 4)
        case .favorite: return (2, 1, 3)
        case .popular: return (2, 1, 5)
        case .discover: return (1, 2, 6)
        }
    }
}
