import Foundation

/// Paging contract for the Медиатека playlist shelf.
///
/// `audio.getPlaylists` returns followed albums next to playlists, and those
/// album objects are dropped client-side. A library whose first page is
/// mostly albums would therefore show a nearly empty shelf if the app only
/// ever asked for one page, so the shelf pulls several pages up front the
/// way the album shelf already does.
enum LibraryPlaylistPagePolicy {
    /// VK caps `audio.getPlaylists` at 100 entries per request.
    static let pageSize = 100

    /// Pages requested when the library opens. Loading stops early as soon
    /// as VK reports no further offset.
    static let prefetchPages = 5

    /// Raw entries scanned by the initial load in the worst case.
    static var prefetchCapacity: Int { pageSize * prefetchPages }

    /// Offset of the page after `offset`, or `nil` once VK says the list is
    /// exhausted. `received` counts raw entries, including the album
    /// objects that never reach the shelf: advancing by the number of
    /// decoded playlists instead would re-request the same window forever.
    static func nextOffset(
        after offset: Int,
        received: Int,
        total: Int
    ) -> Int? {
        guard received > 0 else { return nil }
        let consumed = offset + received
        return consumed < total ? consumed : nil
    }
}
