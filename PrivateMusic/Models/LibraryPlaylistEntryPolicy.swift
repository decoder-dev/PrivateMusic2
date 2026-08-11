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
/// (`album_type` is a release type), backs that up with a second release
/// marker, and carries no playlist marker at all. Everything else stays a
/// playlist: a release that slips through still renders a working card,
/// while a dropped playlist is simply gone from the shelf.
///
/// Followed albums that survive this test do not reach the shelf either —
/// `LibraryPlaylistShelfPolicy` drops every entry the Albums shelf already
/// loaded by identity (`owner_id` + `id`), which cannot mistake a playlist
/// for a release.
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
    static func looksLikeFollowedAlbum(_ entry: LibraryPlaylistEntry) -> Bool {
        guard !hasPlaylistMarker(entry), hasReleaseAlbumType(entry) else {
            return false
        }
        return corroboratingReleaseMarkers(entry) >= 1
    }

    /// `true` for an entry that belongs to the Albums shelf.
    ///
    /// The Albums shelf loads `audio.getPlaylists` with
    /// `filters=followed,albums`, and `followed` covers the playlists you
    /// saved from other people as much as it covers releases. Every one of
    /// those entries decodes as an `Album`, and the playlist shelf subtracts
    /// exactly the ids that list reports — so a saved playlist left in it
    /// disappeared from Медиатека altogether.
    ///
    /// The test is the mirror of `hasPlaylistMarker`, not of
    /// `looksLikeFollowedAlbum`: an entry VK marked as person-made is a
    /// playlist wherever it turns up, and a release never carries those
    /// markers, so nothing that belongs on the Albums shelf is lost here.
    static func belongsOnAlbumsShelf(_ entry: LibraryPlaylistEntry) -> Bool {
        !hasPlaylistMarker(entry)
    }
}
