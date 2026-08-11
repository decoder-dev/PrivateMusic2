import Foundation

/// Normalizes the playlist collection behind the library shelf.
///
/// The same logical playlist can arrive twice from `audio.getPlaylists`:
/// once as the copy you own and once as the copy you follow. VK also hands
/// back a numbered clone («Мне нравится (2)») when the liked playlist is
/// saved again. Both land in the shelf as duplicate cards, so the shelf
/// collapses them here instead of asking SwiftUI to render two cards for
/// one playlist.
///
/// Title collapsing is deliberately limited to the VK system liked
/// playlist. Broad favourite wording — «любимое», «избранное», Favorites —
/// is what people call their own hand-made playlists, and collapsing those
/// wiped real playlists off Медиатека.
enum LibraryPlaylistShelfPolicy {
    /// Titles VK gives the automatic liked playlist, in every locale the
    /// app has seen. Nothing else collapses by title — «Избранное» or
    /// «Рок (2)» stay separate cards.
    private static let likedTitles: Set<String> = [
        "мне нравится",
        "мне нравятся",
        "liked songs"
    ]

    /// - Parameter followedAlbumIdentities: owner-scoped ids of the albums
    ///   the Albums shelf already loaded through `filters=albums`. VK reports
    ///   those albums in the unfiltered playlist list too, and this is the
    ///   only way to recognise them that cannot mistake a real playlist for a
    ///   release — provided the list itself holds nothing but releases.
    ///
    ///   That proviso is the whole defect: the Albums shelf used to ask for
    ///   `filters=followed,albums`, and `filters` unions its categories, so
    ///   the list also held every playlist saved from another person. Each of
    ///   them was subtracted here, leaving only the playlists the user made
    ///   themselves. `LibraryPlaylistPagePolicy.albumShelfFilters` now asks
    ///   for the releases alone, and `LibraryPlaylistEntryPolicy` still
    ///   classifies the answer entry by entry as a second line of defence.
    static func normalized(
        _ items: [Playlist],
        ownerID: Int? = nil,
        followedAlbumIdentities: Set<String> = []
    ) -> [Playlist] {
        var seenIdentities = Set<String>()
        var unique: [Playlist] = []
        for item in items {
            guard !isFollowedAlbum(
                item,
                ownerID: ownerID,
                identities: followedAlbumIdentities
            ),
                  seenIdentities.insert(item.libraryIdentity).inserted else {
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

    /// A playlist the Albums shelf already shows as a release.
    ///
    /// A playlist you made yourself is never one of them — VK has no way for
    /// a person to own a release — so your own playlists are held back from
    /// this test entirely. It is the last line of defence for the shelf that
    /// three releases in a row came back empty-handed on: an id that matches
    /// something on the Albums shelf while it belongs to you is a fault in
    /// that shelf, not a reason to hide your playlist.
    private static func isFollowedAlbum(
        _ item: Playlist,
        ownerID: Int?,
        identities: Set<String>
    ) -> Bool {
        guard item.ownerID != ownerID else { return false }
        return identities.contains(item.libraryIdentity)
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
