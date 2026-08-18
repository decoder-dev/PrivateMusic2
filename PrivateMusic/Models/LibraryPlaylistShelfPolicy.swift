import Foundation

/// Normalizes the playlist collection behind the library shelf.
///
/// The shelf is allowed to remove exactly two things, and nothing else:
///
/// 1. the very same playlist listed twice (same `owner_id` + `id`), which
///    `audio.getPlaylists` does whenever a page arrives split across
///    several blocks;
/// 2. the VK system liked playlist listed twice under the *same* title —
///    once as the copy you own and once as the copy you follow.
///
/// Everything else is a playlist somebody made, and a playlist that is not
/// on Медиатека is worse than a card too many. That includes «Мне
/// нравится (2)»: VK hands out a numbered clone when the liked playlist is
/// saved again, and that clone has its own id and its own tracks, so it is
/// a separate card. Collapsing it took a real playlist off the shelf.
///
/// Title collapsing is deliberately limited to the VK system liked
/// playlist. Broad favourite wording — «любимое», «избранное», Favorites —
/// is what people call their own hand-made playlists, and collapsing those
/// wiped real playlists off Медиатека.
///
/// The shelf also no longer subtracts the ids the Albums shelf reports.
/// That subtraction is the defect users reported over and over: whatever
/// the Albums shelf mistakes for a release disappears from Медиатека
/// altogether, so a single wrong entry there — or a `filters` VK chose not
/// to honour — emptied the shelf down to one card. Followed releases are
/// kept off the shelf entry by entry instead, by
/// `LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum`, which can only ever
/// drop an entry VK itself typed as a release.
enum LibraryPlaylistShelfPolicy {
    /// Titles VK gives the automatic liked playlist, in every locale the
    /// app has seen. Nothing else collapses by title — «Избранное», «Рок
    /// (2)» and «Мне нравится (2)» all stay separate cards.
    private static let likedTitles: Set<String> = [
        "мне нравится",
        "мне нравятся",
        "liked songs"
    ]

    static func normalized(
        _ items: [Playlist],
        ownerID: Int? = nil
    ) -> [Playlist] {
        var seenIdentities = Set<String>()
        var unique: [Playlist] = []
        for item in items
        where seenIdentities.insert(item.libraryIdentity).inserted {
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

    /// Liked releases VK still hands back as playlists share the same
    /// `owner_id` + `id` as their Albums-shelf card. Drop them here so a
    /// followed album never renders twice — once as a playlist chip and
    /// once on the Albums shelf.
    static func excludingLikedAlbums(
        _ playlists: [Playlist],
        likedAlbumCompositeIDs: Set<String>
    ) -> [Playlist] {
        guard !likedAlbumCompositeIDs.isEmpty else { return playlists }
        return playlists.filter {
            !likedAlbumCompositeIDs.contains($0.libraryIdentity)
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
    ///
    /// The title has to *be* a liked title, marker and all. «Мне
    /// нравится (2)» is a playlist of its own, not a second rendering of
    /// the liked one, so it never shares a key with «Мне нравится».
    static func likedKey(for title: String) -> String? {
        let normalized = normalizedTitle(title)
        return likedTitles.contains(normalized) ? normalized : nil
    }

    /// Lowercases, folds `ё` and squeezes whitespace. Nothing is stripped
    /// off the end: a trailing ` (2)` is part of the name VK gave the
    /// playlist, and treating it as noise merged two separate playlists
    /// into one card.
    static func normalizedTitle(_ title: String) -> String {
        title
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: nil
            )
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
