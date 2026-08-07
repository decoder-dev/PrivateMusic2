import Foundation

struct MixRationale: Equatable, Sendable {
    let lines: [String]

    var isEmpty: Bool { lines.isEmpty }

    static let empty = MixRationale(lines: [])
}

enum MixRationaleBuilder {
    /// Builds short, evidence-based anchors from local listening history and
    /// the already-loaded mix queue. Never claims VK selected the mix for a
    /// reason — only describes overlaps the user can verify.
    static func build(
        mixTracks: [Track],
        history: [ListeningHistoryEntry],
        recommendations: [Track] = [],
        limit: Int = 3
    ) -> MixRationale {
        guard !mixTracks.isEmpty else { return .empty }

        let mixArtists = frequencyMap(
            mixTracks.map { normalized($0.artist) }.filter { !$0.isEmpty }
        )
        let recentArtists = frequencyMap(
            history.prefix(40).map { normalized($0.track.artist) }
                .filter { !$0.isEmpty }
        )
        let recommendationArtists = Set(
            recommendations.prefix(40).map { normalized($0.artist) }
                .filter { !$0.isEmpty }
        )

        var lines: [String] = []

        let sharedRecent = mixArtists.keys.filter { recentArtists[$0] != nil }
            .sorted {
                (recentArtists[$0] ?? 0, mixArtists[$0] ?? 0)
                    > (recentArtists[$1] ?? 0, mixArtists[$1] ?? 0)
            }
        if let top = sharedRecent.first {
            let display = displayArtist(top, from: mixTracks)
                ?? displayArtist(top, from: history.map(\.track))
                ?? top
            lines.append(
                L10n.format("Часто слушаете: %@", display)
            )
        }

        let sharedRecommended = mixArtists.keys.filter {
            recommendationArtists.contains($0) && !sharedRecent.contains($0)
        }
        if lines.count < limit, let top = sharedRecommended.first {
            let display = displayArtist(top, from: mixTracks)
                ?? displayArtist(top, from: recommendations)
                ?? top
            lines.append(
                L10n.format("Пересекается с рекомендациями: %@", display)
            )
        }

        if lines.count < limit {
            let albums = Set(
                mixTracks.compactMap { track -> String? in
                    guard let album = track.albumTitle.map(normalized),
                          !album.isEmpty else {
                        return nil
                    }
                    return album
                }
            )
            let historyAlbums = Set(
                history.prefix(40).compactMap { entry -> String? in
                    guard let album = entry.track.albumTitle.map(normalized),
                          !album.isEmpty else {
                        return nil
                    }
                    return album
                }
            )
            if !albums.intersection(historyAlbums).isEmpty {
                lines.append(L10n.text("Есть альбомы из недавних прослушиваний"))
            }
        }

        if lines.isEmpty {
            lines.append(L10n.text("Подобрано под ваш недавний вкус"))
        }

        return MixRationale(lines: Array(lines.prefix(limit)))
    }

    private static func frequencyMap(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func displayArtist(
        _ normalizedName: String,
        from tracks: [Track]
    ) -> String? {
        tracks.first {
            normalized($0.artist) == normalizedName
        }?.artist
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
