import Foundation

@MainActor
final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    private var nextOffset: Int?
    private var ownerID: Int?
    private var followedAlbumIdentities: Set<String> = []
    /// A prefetch cut short by cancellation (tab switch, token change) must
    /// not count as done: without this the next unforced load saw a
    /// non-empty list and returned, leaving the shelf stuck on whichever
    /// page happened to land first.
    private var didFinishPrefetch = false

    /// Lets the shelf prefer the copy of a duplicated system playlist that
    /// the signed-in user actually owns, and drop the followed albums the
    /// Albums shelf already owns.
    func configure(ownerID: Int?, followedAlbumIdentities: Set<String> = []) {
        self.ownerID = ownerID
        self.followedAlbumIdentities = followedAlbumIdentities
    }

    /// The Albums shelf loads in parallel with the playlist prefetch, so the
    /// exclusion set can arrive after the first pages. Re-filter in place
    /// rather than refetching the list.
    func excludeFollowedAlbums(_ identities: Set<String>) {
        guard identities != followedAlbumIdentities else { return }
        followedAlbumIdentities = identities
        publish(playlists)
    }

    /// Loads the opening pages of the playlist list. VK mixes followed
    /// albums into `audio.getPlaylists`, so a single page can decode into
    /// only a handful of playlists — the shelf pulls several pages up front
    /// and publishes each one as it lands.
    func load(
        force: Bool = false,
        pages: Int = LibraryPlaylistPagePolicy.prefetchPages,
        operation: (Int) async throws -> MusicPage<Playlist>
    ) async {
        guard !isLoading, force || !didFinishPrefetch else { return }
        isLoading = true
        defer { isLoading = false }
        var collected: [Playlist] = []
        var offset = 0
        var pending: Int?
        do {
            for _ in 0..<max(pages, 1) {
                let page = try await operation(offset)
                collected.append(contentsOf: page.items)
                publish(collected)
                guard let next = page.nextOffset, next > offset else {
                    pending = nil
                    break
                }
                offset = next
                pending = next
            }
            nextOffset = pending
            didFinishPrefetch = true
            errorMessage = nil
        } catch is CancellationError {
            // Keep the offset so the shelf's own pagination can pick the
            // walk back up, and leave the prefetch marked unfinished.
            nextOffset = pending
        } catch {
            // A failed later page must not throw away the playlists that
            // already loaded: keep them and leave the offset for the
            // shelf's own pagination to retry.
            nextOffset = pending
            errorMessage = collected.isEmpty
                ? error.localizedDescription
                : nil
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Playlist>
    ) async {
        guard !isLoading,
              !isLoadingMore,
              let offset = nextOffset else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await operation(offset)
            publish(playlists + page.items)
            nextOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(
        _ playlist: Playlist,
        service: any MusicService,
        accessToken: String
    ) async {
        do {
            try await service.deletePlaylist(
                playlist,
                accessToken: accessToken
            )
            removeLocally(playlist)
            errorMessage = nil
            MusicLibraryEvents.postPlaylistsChanged(removed: playlist)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeLocally(_ playlist: Playlist) {
        playlists.removeAll { $0.libraryIdentity == playlist.libraryIdentity }
    }

    private func publish(_ collected: [Playlist]) {
        let normalized = LibraryPlaylistShelfPolicy.normalized(
            collected,
            ownerID: ownerID,
            followedAlbumIdentities: followedAlbumIdentities
        )
        // Republishing an identical list would rebuild every shelf card for
        // nothing — the prefetch walks up to five pages, so that is four
        // wasted layout passes on a library that fits in one page.
        guard normalized.map(\.libraryIdentity)
            != playlists.map(\.libraryIdentity) else {
            return
        }
        playlists = normalized
    }
}
