import Foundation

/// Single-user artist co-occurrence from listening history — a local
/// item-based CF sketch (Sarwar et al.), not cross-user collaborative
/// filtering. Gives Selena seed rotation material beyond "last played".
enum ArtistCooccurrenceIndex {
    /// Build `[artistKey: [neighborKey: count]]` from sliding windows.
    static func build(
        history: [ListeningHistoryEntry],
        window: Int = 10
    ) -> [String: [String: Int]] {
        let keys = history.map {
            MixFeedbackPolicy.normalized($0.track.artist)
        }.filter { !$0.isEmpty }
        guard keys.count > 1, window > 0 else { return [:] }

        var table: [String: [String: Int]] = [:]
        for (index, key) in keys.enumerated() {
            let start = max(0, index - window)
            let end = min(keys.count, index + window + 1)
            for otherIndex in start..<end where otherIndex != index {
                let other = keys[otherIndex]
                guard other != key else { continue }
                table[key, default: [:]][other, default: 0] += 1
            }
        }
        return table
    }

    /// Ranked neighbor artists for a seed key.
    static func neighbors(
        of artistKey: String,
        in table: [String: [String: Int]],
        limit: Int = 8
    ) -> [String] {
        guard let row = table[artistKey] else { return [] }
        return row.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        .prefix(limit)
        .map(\.key)
    }

    /// Pick seed tracks whose artists co-occur with recent listening,
    /// falling back to the original seed list order.
    static func boostSeeds(
        _ seeds: [Track],
        history: [ListeningHistoryEntry],
        limit: Int = 32
    ) -> [Track] {
        guard !seeds.isEmpty, !history.isEmpty else {
            return Array(seeds.prefix(limit))
        }
        let table = build(history: history)
        let recentKeys = history.prefix(12).map {
            MixFeedbackPolicy.normalized($0.track.artist)
        }.filter { !$0.isEmpty }
        var neighborBoost = Set<String>()
        for key in recentKeys {
            for neighbor in neighbors(of: key, in: table, limit: 6) {
                neighborBoost.insert(neighbor)
            }
        }
        guard !neighborBoost.isEmpty else {
            return Array(seeds.prefix(limit))
        }

        var boosted: [Track] = []
        var rest: [Track] = []
        var seen = Set<String>()
        for track in seeds {
            guard seen.insert(track.id).inserted else { continue }
            let key = MixFeedbackPolicy.normalized(track.artist)
            if neighborBoost.contains(key) {
                boosted.append(track)
            } else {
                rest.append(track)
            }
        }
        return Array((boosted + rest).prefix(limit))
    }
}
