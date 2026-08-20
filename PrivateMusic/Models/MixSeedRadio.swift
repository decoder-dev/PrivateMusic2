import Foundation

/// Builds seed-driven mix queues the way official VK Music advertises:
/// «микс по треку», «микс по моей музыке» — without undocumented mix filters.
enum MixSeedRadio {
    /// Interleave library seeds with recommendations so the stream opens on
    /// familiar taste but keeps discovering. Dedupes by track id.
    static func blend(
        seeds: [Track],
        recommendations: [Track],
        limit: Int = MixTrackRequestPolicy.queueLimit
    ) -> [Track] {
        var known = Set<String>()
        var result: [Track] = []
        result.reserveCapacity(min(limit, seeds.count + recommendations.count))

        let seedPool = Array(seeds.shuffled().prefix(24))
        let recPool = Array(recommendations.prefix(limit))

        var seedIndex = 0
        var recIndex = 0
        var takeSeed = true
        while result.count < limit,
              (seedIndex < seedPool.count || recIndex < recPool.count) {
            if takeSeed, seedIndex < seedPool.count {
                let track = seedPool[seedIndex]
                seedIndex += 1
                if known.insert(track.id).inserted {
                    result.append(track)
                }
            } else if recIndex < recPool.count {
                let track = recPool[recIndex]
                recIndex += 1
                if known.insert(track.id).inserted {
                    result.append(track)
                }
            } else if seedIndex < seedPool.count {
                let track = seedPool[seedIndex]
                seedIndex += 1
                if known.insert(track.id).inserted {
                    result.append(track)
                }
            } else {
                break
            }
            // Roughly 1 seed : 2 recommendations — closer to official «mix
            // from my music» which leans on the recommender.
            takeSeed = result.count % 3 == 0
        }
        return result
    }

    /// Catalog shelf titles that behave like VK «вайбы» / mood entry points.
    static func looksLikeVibeShelf(_ title: String) -> Bool {
        containsAny(
            title,
            [
                "вайб", "vibe", "настроен", "mood", "активн", "спокойн",
                "грустн", "радост", "любов", "энерг", "relax", "party",
                "work", "спорт", "night", "вечер", "утро", "поездк"
            ]
        )
    }

    static func looksLikeKidsShelf(_ title: String) -> Bool {
        containsAny(
            title,
            ["дет", "kids", "child", "сказк", "колыбел", "семья", "family"]
        )
    }

    static func looksLikeChartShelf(_ title: String) -> Bool {
        containsAny(
            title,
            ["chart", "чарт", "топ", "top ", "хит", "hit", "популяр"]
        )
    }

    private static func containsAny(_ title: String, _ markers: [String]) -> Bool {
        // Fold haystack *and* needles the same way. Diacritic-insensitive
        // folding turns й→и, so raw markers like "вайб" / "спокойн" would
        // never match a folded shelf title.
        let locale = Locale(identifier: "ru_RU")
        func fold(_ value: String) -> String {
            value
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: locale
                )
                .lowercased()
        }
        let blob = fold(title)
        return markers.contains { blob.contains(fold($0)) }
    }
}
