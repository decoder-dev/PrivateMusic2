import Foundation

/// Paging contract for the Медиатека playlist shelf.
///
/// `audio.getPlaylists` returns followed albums next to playlists, and the
/// albums the Albums shelf already owns are dropped client-side. A library
/// whose first page is mostly albums would therefore show a nearly empty
/// shelf if the app only ever asked for one page, so the shelf walks the
/// list to its end when the library opens.
enum LibraryPlaylistPagePolicy {
    /// VK caps `audio.getPlaylists` at 100 entries per request.
    static let pageSize = 100

    /// `filters` for the Albums shelf request.
    ///
    /// `filters` is a union of the categories named in it — `all` (default),
    /// `owned`, `followed`, `albums` — not a chain of qualifiers. Asking for
    /// `followed,albums` therefore returned every playlist saved from
    /// another person *as well as* the releases, and since the playlist
    /// shelf subtracts the ids this list reports, each of those playlists
    /// vanished from Медиатека and only the ones the user made themselves
    /// were left. `albums` alone is the releases, which is the only thing
    /// the Albums shelf ever wanted.
    static let albumShelfFilters = "albums"

    /// Upper bound on the pages the opening walk may request. It is a
    /// runaway guard, not a target: the walk stops as soon as VK reports no
    /// further offset, which for an ordinary library is after one request.
    /// Stopping at five pages was a target, and it left the shelf short on
    /// libraries whose playlists sit behind a few hundred followed albums.
    static let prefetchPages = 40

    /// Raw entries scanned by the initial load in the worst case.
    static var prefetchCapacity: Int { pageSize * prefetchPages }

    /// Pause before the walk asks for a failed page a second time. On 3G a
    /// page times out often enough that ending the walk there left the
    /// shelf short of playlists until the next pull-to-refresh.
    static let retryDelay: TimeInterval = 0.6

    /// Offset of the page after `offset`, or `nil` once VK says the list is
    /// exhausted.
    ///
    /// `received` counts raw entries, including the album objects that never
    /// reach the shelf: advancing by the number of decoded playlists instead
    /// would re-request the same window forever.
    ///
    /// A full page always continues, whatever `total` claims. VK's `count`
    /// for the unfiltered list does not always describe the same set as
    /// `items` — when it under-reports, trusting it alone stopped the walk
    /// on the first page and hid every playlist behind it.
    static func nextOffset(
        after offset: Int,
        received: Int,
        requested: Int = pageSize,
        total: Int
    ) -> Int? {
        guard received > 0 else { return nil }
        let consumed = offset + received
        if requested > 0, received >= requested { return consumed }
        return consumed < total ? consumed : nil
    }
}
