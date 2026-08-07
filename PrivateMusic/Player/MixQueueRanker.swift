import Foundation

enum MixRadioMode: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case closerToSeed
    case moreNovel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return L10n.text("Баланс")
        case .closerToSeed:
            return L10n.text("Ближе к треку")
        case .moreNovel:
            return L10n.text("Больше новизны")
        }
    }
}

enum MixQueueRanker {
    /// Reorders only the unplayed suffix. Preserves played prefix + current.
    ///
    /// All modes (including Баланс) diversify the upcoming queue: artist
    /// spacing, novelty/affinity scoring, and light jitter so equal scores
    /// do not freeze VK's original clustered order.
    static func rerank(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String> = []
    ) -> [Track] {
        var rng = SystemRandomNumberGenerator()
        return rerank(
            queue: queue,
            currentIndex: currentIndex,
            seed: seed,
            mode: mode,
            historyArtists: historyArtists,
            rng: &rng
        )
    }

    static func rerank<G: RandomNumberGenerator>(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String> = [],
        rng: inout G
    ) -> [Track] {
        guard queue.indices.contains(currentIndex) else { return queue }
        let head = Array(queue.prefix(currentIndex + 1))
        var remaining = Array(queue.suffix(from: currentIndex + 1))
        guard remaining.count > 1 else { return queue }

        let seedArtist = normalized(seed.artist)
        let seedAlbum = seed.albumTitle.map(normalized) ?? ""
        let history = Set(historyArtists.map(normalized))

        var recentArtists = head.suffix(4).map { normalized($0.artist) }
        var built: [Track] = []
        built.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.greatestFiniteMagnitude
            for (index, track) in remaining.enumerated() {
                let value = score(
                    track,
                    seedArtist: seedArtist,
                    seedAlbum: seedAlbum,
                    history: history,
                    recentArtists: recentArtists,
                    mode: mode,
                    rng: &rng
                )
                if value > bestScore {
                    bestScore = value
                    bestIndex = index
                }
            }
            let picked = remaining.remove(at: bestIndex)
            built.append(picked)
            recentArtists.append(normalized(picked.artist))
            if recentArtists.count > 5 {
                recentArtists.removeFirst(recentArtists.count - 5)
            }
        }

        return head + built
    }

    private static func score<G: RandomNumberGenerator>(
        _ track: Track,
        seedArtist: String,
        seedAlbum: String,
        history: Set<String>,
        recentArtists: [String],
        mode: MixRadioMode,
        rng: inout G
    ) -> Double {
        let artist = normalized(track.artist)
        let album = track.albumTitle.map(normalized) ?? ""
        var value = 0.0

        switch mode {
        case .balanced:
            if !seedArtist.isEmpty, artist == seedArtist { value += 6 }
            if !seedArtist.isEmpty, artist != seedArtist { value += 14 }
            if !history.contains(artist) { value += 12 }
            if history.contains(artist) { value -= 6 }
            if !seedAlbum.isEmpty, album != seedAlbum { value += 5 }
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -48,
                near: -22,
                window: -10
            )
            // Soft shuffle so Balans is not a frozen sort of VK order.
            value += Double.random(in: 0..<8, using: &rng)

        case .closerToSeed:
            if !seedArtist.isEmpty, artist == seedArtist { value += 42 }
            if !seedAlbum.isEmpty, album == seedAlbum { value += 18 }
            if history.contains(artist) { value += 6 }
            if !seedArtist.isEmpty, artist != seedArtist { value += 4 }
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -36,
                near: -16,
                window: -6
            )
            value += Double.random(in: 0..<4, using: &rng)

        case .moreNovel:
            if !seedArtist.isEmpty, artist != seedArtist { value += 32 }
            if !seedArtist.isEmpty, artist == seedArtist { value -= 18 }
            if !history.contains(artist) { value += 26 }
            if history.contains(artist) { value -= 16 }
            if !seedAlbum.isEmpty, album != seedAlbum { value += 8 }
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -55,
                near: -28,
                window: -12
            )
            value += Double.random(in: 0..<10, using: &rng)
        }

        return value
    }

    /// Penalize repeating an artist that just played — the main reason
    /// mix radio felt like the same handful of picks on loop.
    private static func spacingBonus(
        artist: String,
        recent: [String],
        immediate: Double,
        near: Double,
        window: Double
    ) -> Double {
        guard !artist.isEmpty, !recent.isEmpty else { return 0 }
        if recent.last == artist { return immediate }
        if recent.suffix(2).contains(artist) { return near }
        if recent.contains(artist) { return window }
        return 12
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
