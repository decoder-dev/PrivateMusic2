import Foundation

/// Keeps the artist «Альбомы» shelf from painting sparse or mis-parsed
/// VK payloads as empty grey cards.
enum ArtistAlbumShelfPolicy {
    /// An album list entry that has neither a track count nor artwork —
    /// the shape `audio.getAlbumsByArtist` often returns, and the shape a
    /// mis-parsed audio row always has after `Album` decode.
    static func isIncomplete(_ album: Album) -> Bool {
        album.count <= 0 && album.artworkURL == nil
    }

    /// Whether the primary list is so thin that the catalog artist page
    /// should replace it instead of being skipped by a non-empty early return.
    static func shouldPreferCatalog(over list: [Album]) -> Bool {
        !list.isEmpty && list.allSatisfy(isIncomplete)
    }

    /// Prefer catalog metadata when both sides name the same release;
    /// keep list-only entries that already look complete.
    static func merging(list: [Album], catalog: [Album]) -> [Album] {
        guard !catalog.isEmpty else { return list }
        var byID: [String: Album] = [:]
        var order: [String] = []
        for album in list {
            let id = album.compositeID
            if byID[id] == nil {
                order.append(id)
            }
            byID[id] = album
        }
        for album in catalog {
            let id = album.compositeID
            if let existing = byID[id] {
                byID[id] = existing.mergingAccessMetadata(from: album)
            } else if !isIncomplete(album) {
                order.append(id)
                byID[id] = album
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Fill count/artwork from co-loaded artist tracks, then drop cards that
    /// are still empty — those were almost certainly audio rows mistaken for
    /// albums, not releases the user can open.
    static func displaying(
        _ albums: [Album],
        using tracks: [Track]
    ) -> [Album] {
        albums.compactMap { album in
            let related = relatedTracks(to: album, in: tracks)
            let enriched = album.normalized(using: related)
            if isIncomplete(enriched) {
                return nil
            }
            return enriched
        }
    }

    private static func relatedTracks(
        to album: Album,
        in tracks: [Track]
    ) -> [Track] {
        tracks.filter { track in
            if let reference = track.albumReference {
                return reference.albumID == album.albumID
                    && reference.ownerID == album.ownerID
            }
            guard Album.isUsableTitle(album.title),
                  let albumTitle = track.albumTitle,
                  Album.isUsableTitle(albumTitle) else {
                return false
            }
            return albumTitle.caseInsensitiveCompare(album.title)
                == .orderedSame
        }
    }
}
