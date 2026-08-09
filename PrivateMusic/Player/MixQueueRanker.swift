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

    /// Segmented pickers clip the full titles on compact widths.
    var compactTitle: String {
        switch self {
        case .balanced:
            return L10n.text("Баланс")
        case .closerToSeed:
            return L10n.text("Ближе")
        case .moreNovel:
            return L10n.text("Новизна")
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
        let remaining = Array(queue.suffix(from: currentIndex + 1))
        guard remaining.count > 1 else { return queue }

        let seedArtist = normalized(seed.artist)
        let seedAlbum = seed.albumTitle.map(normalized) ?? ""
        let history = Set(historyArtists.map(normalized))

        let built: [Track]
        switch mode {
        case .balanced:
            built = diversifyBalanced(remaining, rng: &rng)
        case .closerToSeed, .moreNovel:
            built = greedilyRank(
                remaining,
                seedArtist: seedArtist,
                seedAlbum: seedAlbum,
                history: history,
                head: head,
                mode: mode,
                rng: &rng
            )
        }

        return head + built
    }

    /// Shuffle then repair adjacent same-artist pairs so VK clusters do
    /// not survive as a no-op «Баланс» ordering.
    private static func diversifyBalanced<G: RandomNumberGenerator>(
        _ upcoming: [Track],
        rng: inout G
    ) -> [Track] {
        var items = upcoming
        items.shuffle(using: &rng)
        guard items.count > 1 else { return items }

        for index in 1..<items.count {
            let prev = normalized(items[index - 1].artist)
            let current = normalized(items[index].artist)
            guard !prev.isEmpty, prev == current else { continue }
            if let swapIndex = (index + 1..<items.count).first(where: {
                let artist = normalized(items[$0].artist)
                return artist != prev
            }) {
                items.swapAt(index, swapIndex)
            }
        }
        return items
    }

    private static func greedilyRank<G: RandomNumberGenerator>(
        _ upcoming: [Track],
        seedArtist: String,
        seedAlbum: String,
        history: Set<String>,
        head: [Track],
        mode: MixRadioMode,
        rng: inout G
    ) -> [Track] {
        var remaining = upcoming
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
        return built
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
            break
        case .closerToSeed:
            if !seedArtist.isEmpty, artist == seedArtist { value += 42 }
            if !seedAlbum.isEmpty, album == seedAlbum { value += 18 }
            if history.contains(artist) { value += 6 }
            if !seedArtist.isEmpty, artist != seedArtist { value += 4 }
            // Mild spacing only — affinity to the seed artist must still win
            // the first pick after the current track.
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -16,
                near: -8,
                window: -3,
                fresh: 0
            )
            value += Double.random(in: 0..<3, using: &rng)

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
                window: -12,
                fresh: 12
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
        window: Double,
        fresh: Double
    ) -> Double {
        guard !artist.isEmpty else { return 0 }
        guard !recent.isEmpty else { return fresh }
        if recent.last == artist { return immediate }
        if recent.suffix(2).contains(artist) { return near }
        if recent.contains(artist) { return window }
        return fresh
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
