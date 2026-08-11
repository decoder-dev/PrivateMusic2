import Foundation

/// The shape of one `audio.getPlaylists` entry, reduced to the fields that
/// say whether VK handed back a playlist or a followed release.
struct LibraryPlaylistEntry: Equatable, Sendable {
    /// VK `album_type`: `playlist`, `collection`, `album`, `single`, `ep`,
    /// `compilation`, `main_only`, or absent.
    var albumType: String?
    /// Non-empty `main_artists`.
    var hasMainArtists: Bool
    /// `year` or `original_year`.
    var hasReleaseYear: Bool
    /// VK `type`: `1` on releases — and on playlists saved from another
    /// owner, which is what made this marker useless on its own.
    var vkType: Int?
    /// The `original` object VK attaches to a playlist you saved from
    /// someone else.
    var hasOriginalPlaylist: Bool

    init(
        albumType: String? = nil,
        hasMainArtists: Bool = false,
        hasReleaseYear: Bool = false,
        vkType: Int? = nil,
        hasOriginalPlaylist: Bool = false
    ) {
        self.albumType = albumType
        self.hasMainArtists = hasMainArtists
        self.hasReleaseYear = hasReleaseYear
        self.vkType = vkType
        self.hasOriginalPlaylist = hasOriginalPlaylist
    }
}

/// Tells followed releases apart from playlists in the unfiltered
/// `audio.getPlaylists` list.
///
/// Users reported the same defect three times in a row: playlists kept
/// vanishing from Медиатека because this test was too eager. VK stamps
/// release-looking metadata on ordinary playlists — a playlist saved from
/// another owner comes back as `type: 1`, a playlist built off an artist
/// page carries `main_artists`, «Итоги 2019» carries a `year` — so no
/// combination of those *inferred* markers is evidence of a release.
///
/// An entry is therefore treated as a release only when VK typed it as one
/// (`album_type` is a release type), named the artists behind it, backs
/// that up with a year or `type: 1`, and carries no playlist marker at
/// all. Everything else stays a
/// playlist: a release that slips through still renders a working card,
/// while a dropped playlist is simply gone from the shelf.
///
/// This is the only test that keeps a release off Медиатека. The shelf used
/// to also subtract every id the Albums shelf reported, and that is what
/// left the reporter with one card out of eight: anything the Albums shelf
/// mistook for a release vanished from the playlist shelf too.
enum LibraryPlaylistEntryPolicy {
    /// `album_type` values VK uses for a release. `main_only` is what a
    /// plain studio release reports.
    static let releaseAlbumTypes: Set<String> = [
        "album", "single", "ep", "compilation", "main_only"
    ]

    /// `album_type` values VK uses for something a person assembled.
    static let playlistAlbumTypes: Set<String> = ["playlist", "collection"]

    /// Markers only a person-made list carries.
    static func hasPlaylistMarker(_ entry: LibraryPlaylistEntry) -> Bool {
        if entry.hasOriginalPlaylist { return true }
        if let albumType = entry.albumType?.lowercased(),
           playlistAlbumTypes.contains(albumType) {
            return true
        }
        return false
    }

    /// VK explicitly typed the entry as a release.
    static func hasReleaseAlbumType(_ entry: LibraryPlaylistEntry) -> Bool {
        guard let albumType = entry.albumType?.lowercased() else {
            return false
        }
        return releaseAlbumTypes.contains(albumType)
    }

    /// Release evidence that is not the `album_type` itself. Every one of
    /// these also shows up on real playlists, so they only ever corroborate
    /// an explicit release type — never trigger a drop on their own.
    static func corroboratingReleaseMarkers(
        _ entry: LibraryPlaylistEntry
    ) -> Int {
        var markers = 0
        if entry.hasMainArtists { markers += 1 }
        if entry.hasReleaseYear { markers += 1 }
        if entry.vkType == 1 { markers += 1 }
        return markers
    }

    /// `true` only for an entry that is unmistakably a followed release.
    ///
    /// Three things have to line up: VK typed the entry as a release, named
    /// the artists behind it, and dated it (or flagged it as a release with
    /// `type: 1`). Artist attribution is required on its own because that
    /// is what a release always carries and a person-made list almost
    /// never does — and the one list that does carry it, the one built off
    /// an artist page, is not also typed as a release.
    ///
    /// A release that fails any of these stays on the playlist shelf as an
    /// extra card, and still reaches the Albums shelf through
    /// `belongsOnAlbumsShelf`. That is the trade this whole file is built
    /// around: a card too many is a blemish, a playlist that never arrives
    /// is the defect users keep reporting.
    static func looksLikeFollowedAlbum(_ entry: LibraryPlaylistEntry) -> Bool {
        guard !hasPlaylistMarker(entry), hasReleaseAlbumType(entry) else {
            return false
        }
        guard entry.hasMainArtists else { return false }
        return corroboratingReleaseMarkers(entry) >= 2
    }

    /// `true` for an entry that belongs to the Albums shelf.
    ///
    /// The Albums shelf loads `audio.getPlaylists` with `filters=albums`.
    /// `filters` unions the categories it names rather than qualifying
    /// them, so the old `followed,albums` answered with every playlist
    /// saved from another person as well — each of which decodes as an
    /// `Album` just fine. The request is narrowed now, and this test stays
    /// as the second line of defence for anything VK still leaves in the
    /// answer.
    ///
    /// Getting it wrong now costs a card on the Albums shelf and nothing
    /// else: the playlist shelf no longer subtracts the ids this list
    /// reports, so a misread entry cannot take a playlist off Медиатека.
    ///
    /// The test is the mirror of `hasPlaylistMarker`, not of
    /// `looksLikeFollowedAlbum`: an entry VK marked as person-made is a
    /// playlist wherever it turns up, and a release never carries those
    /// markers, so nothing that belongs on the Albums shelf is lost here.
    static func belongsOnAlbumsShelf(_ entry: LibraryPlaylistEntry) -> Bool {
        !hasPlaylistMarker(entry)
    }
}
