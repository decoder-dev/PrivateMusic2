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
        limit: Int = 5
    ) -> MixRationale {
        guard !mixTracks.isEmpty else { return .empty }

        let mixArtists = frequencyMap(
            mixTracks.map { MixFeedbackPolicy.normalized($0.artist) }
                .filter { !$0.isEmpty }
        )
        let recentArtists = frequencyMap(
            history.prefix(40).map { MixFeedbackPolicy.normalized($0.track.artist) }
                .filter { !$0.isEmpty }
        )
        let recommendationArtists = Set(
            recommendations.prefix(40).map { MixFeedbackPolicy.normalized($0.artist) }
                .filter { !$0.isEmpty }
        )
        let historyArtistSet = Set(recentArtists.keys)

        var lines: [String] = []

        // Dictionary key order is not stable across launches, so every
        // shortlist is fully ordered — otherwise the same mix explains
        // itself with a different artist each time it is opened.
        let sharedRecent = mixArtists.keys.filter { recentArtists[$0] != nil }
            .sorted {
                let left = (recentArtists[$0] ?? 0, mixArtists[$0] ?? 0)
                let right = (recentArtists[$1] ?? 0, mixArtists[$1] ?? 0)
                if left != right {
                    return left > right
                }
                return $0 < $1
            }
        if let top = sharedRecent.first {
            let display = displayArtist(top, from: mixTracks)
                ?? displayArtist(top, from: history.map(\.track))
                ?? top
            lines.append(
                L10n.format("you_often_listen_to_0", display)
            )
        }

        if lines.count < limit, sharedRecent.count >= 2 {
            let second = sharedRecent[1]
            let display = displayArtist(second, from: mixTracks)
                ?? displayArtist(second, from: history.map(\.track))
                ?? second
            lines.append(
                L10n.format("also_from_recent_listening_0", display)
            )
        }

        let recentSet = Set(sharedRecent)
        let sharedRecommended = mixArtists.keys.filter {
            recommendationArtists.contains($0) && !recentSet.contains($0)
        }
        .sorted {
            let left = mixArtists[$0] ?? 0
            let right = mixArtists[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
        if lines.count < limit, let top = sharedRecommended.first {
            let display = displayArtist(top, from: mixTracks)
                ?? displayArtist(top, from: recommendations)
                ?? top
            lines.append(
                L10n.format("overlaps_recommendations_0", display)
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
                lines.append(L10n.text("includes_albums_from_recent_listening"))
            }
        }

        if lines.count < limit {
            let novelCount = mixArtists.keys.filter {
                !historyArtistSet.contains($0)
            }.count
            let total = max(mixArtists.count, 1)
            let novelPercent = Int(
                (Double(novelCount) / Double(total) * 100).rounded()
            )
            if novelPercent >= 35 {
                lines.append(
                    L10n.format(
                        "about_d0_of_the_artists_are_new_to_your_recent_history",
                        novelPercent
                    )
                )
            } else if mixArtists.count >= 4 {
                lines.append(
                    L10n.format(
                        "d0_different_artists_in_the_stream",
                        mixArtists.count
                    )
                )
            }
        }

        let hqCount = mixTracks.filter(\.isHQ).count
        if lines.count < limit, hqCount >= 3 {
            lines.append(
                L10n.format("hq_recordings_available_d0_in_the_selection", hqCount)
            )
        }

        if lines.isEmpty {
            lines.append(L10n.text("matched_to_your_recent_taste"))
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
            MixFeedbackPolicy.normalized($0.artist) == normalizedName
        }?.artist
    }

}
