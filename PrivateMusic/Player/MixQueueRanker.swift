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
    static func rerank(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String> = []
    ) -> [Track] {
        guard mode != .balanced,
              queue.indices.contains(currentIndex) else {
            return queue
        }
        let head = Array(queue.prefix(currentIndex + 1))
        let upcoming = Array(queue.suffix(from: currentIndex + 1))
        guard upcoming.count > 1 else { return queue }

        let seedArtist = normalized(seed.artist)
        let seedAlbum = seed.albumTitle.map(normalized) ?? ""
        let history = Set(historyArtists.map(normalized))

        let ranked = upcoming.enumerated().sorted { lhs, rhs in
            let left = score(
                lhs.element,
                seedArtist: seedArtist,
                seedAlbum: seedAlbum,
                history: history,
                mode: mode
            )
            let right = score(
                rhs.element,
                seedArtist: seedArtist,
                seedAlbum: seedAlbum,
                history: history,
                mode: mode
            )
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return head + ranked
    }

    private static func score(
        _ track: Track,
        seedArtist: String,
        seedAlbum: String,
        history: Set<String>,
        mode: MixRadioMode
    ) -> Int {
        let artist = normalized(track.artist)
        let album = track.albumTitle.map(normalized) ?? ""
        var value = 0
        switch mode {
        case .balanced:
            break
        case .closerToSeed:
            if !seedArtist.isEmpty, artist == seedArtist { value += 40 }
            if !seedAlbum.isEmpty, album == seedAlbum { value += 20 }
            if history.contains(artist) { value += 8 }
        case .moreNovel:
            if !seedArtist.isEmpty, artist != seedArtist { value += 30 }
            if !history.contains(artist) { value += 20 }
            if !seedAlbum.isEmpty, album != seedAlbum { value += 8 }
        }
        return value
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
