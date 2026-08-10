import Foundation

/// Normalizes the playlist collection behind the library shelf.
///
/// `audio.getPlaylists` runs with `filters=owned,followed`, so the same
/// logical playlist can arrive twice: once as the copy you own and once as
/// the copy you follow. VK also hands back a numbered clone («Мне нравится
/// (2)») when the liked playlist is saved again. Both land in the shelf as
/// duplicate cards, so the shelf collapses them here instead of asking
/// SwiftUI to render two cards for one playlist.
enum LibraryPlaylistShelfPolicy {
    /// Titles VK uses for the automatic "liked" playlist. Only playlists
    /// matching one of these collapse by title — a user's own «Рок (2)»
    /// stays a separate card.
    private static let likedTitles: Set<String> = [
        "мне нравится",
        "мне нравятся",
        "любимое",
        "любимые",
        "любимые треки",
        "избранное",
        "liked",
        "liked songs",
        "favorites",
        "favourites"
    ]

    static func normalized(
        _ items: [Playlist],
        ownerID: Int? = nil
    ) -> [Playlist] {
        var seenIdentities = Set<String>()
        var unique: [Playlist] = []
        for item in items {
            guard seenIdentities.insert(item.libraryIdentity).inserted else {
                continue
            }
            unique.append(item)
        }

        var likedWinners: [String: Playlist] = [:]
        for playlist in unique {
            guard let key = likedKey(for: playlist.title) else { continue }
            guard let incumbent = likedWinners[key] else {
                likedWinners[key] = playlist
                continue
            }
            likedWinners[key] = preferred(
                incumbent,
                over: playlist,
                ownerID: ownerID
            )
        }

        guard !likedWinners.isEmpty else { return unique }
        return unique.filter { playlist in
            guard let key = likedKey(for: playlist.title) else { return true }
            return likedWinners[key]?.libraryIdentity
                == playlist.libraryIdentity
        }
    }

    /// Returns the copy worth keeping: the one you own beats a followed
    /// copy, then the fuller one, then the one that actually has a cover.
    private static func preferred(
        _ lhs: Playlist,
        over rhs: Playlist,
        ownerID: Int?
    ) -> Playlist {
        if let ownerID {
            let lhsOwned = lhs.ownerID == ownerID
            let rhsOwned = rhs.ownerID == ownerID
            if lhsOwned != rhsOwned { return lhsOwned ? lhs : rhs }
        }
        if lhs.count != rhs.count { return lhs.count > rhs.count ? lhs : rhs }
        let lhsHasArtwork = lhs.artworkURL != nil
        let rhsHasArtwork = rhs.artworkURL != nil
        if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork ? lhs : rhs }
        return lhs
    }

    /// `nil` for anything that is not the automatic liked playlist.
    static func likedKey(for title: String) -> String? {
        let normalized = normalizedTitle(title)
        return likedTitles.contains(normalized) ? normalized : nil
    }

    /// Lowercases, folds `ё`, and strips a trailing VK clone marker such as
    /// ` (2)` or ` #2` so «Мне нравится (2)» matches «Мне нравится».
    static func normalizedTitle(_ title: String) -> String {
        var value = title
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: nil
            )
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let marker = cloneMarkerRange(in: value) {
            value = String(value[value.startIndex..<marker.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cloneMarkerRange(
        in value: String
    ) -> Range<String.Index>? {
        for pattern in ["\\s*\\(\\d+\\)$", "\\s*#\\d+$"] {
            if let range = value.range(
                of: pattern,
                options: [.regularExpression]
            ) {
                return range
            }
        }
        return nil
    }
}
