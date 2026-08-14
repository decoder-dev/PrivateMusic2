import Foundation

@MainActor
@Observable
final class PlaylistLibraryViewModel {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    var errorMessage: String?
    private var nextOffset: Int?
    private var ownerID: Int?
    /// A prefetch cut short by cancellation (tab switch, token change) must
    /// not count as done: without this the next unforced load saw a
    /// non-empty list and returned, leaving the shelf stuck on whichever
    /// page happened to land first.
    private var didFinishPrefetch = false
    /// Where an interrupted walk picks back up. Restarting from zero cost
    /// the whole walk again on a 3G connection, and each restart published
    /// a one-page shelf on the way through — the shelf visibly shrank back
    /// to a card or two every time the tab was switched.
    private var prefetchOffset = 0
    /// Everything the walk has collected so far, kept across an interrupted
    /// load so a resumed walk adds to the shelf instead of replacing it.
    private var prefetched: [Playlist] = []

    /// Lets the shelf prefer the copy of a duplicated system playlist that
    /// the signed-in user actually owns.
    ///
    /// The shelf takes no exclusion set from the Albums shelf. Subtracting
    /// the ids that shelf reports is what emptied Медиатека down to one
    /// card: the playlists loaded, then the Albums shelf landed and removed
    /// most of them again.
    func configure(ownerID: Int?) {
        self.ownerID = ownerID
    }

    /// Loads the whole playlist list. VK mixes followed albums into
    /// `audio.getPlaylists`, so a single page can decode into only a handful
    /// of playlists — the shelf walks the list to its end when the library
    /// opens and publishes each page as it lands.
    ///
    /// `pages` is a runaway guard, not a target: the walk stops as soon as
    /// VK reports no further offset. Stopping after a fixed five pages left
    /// playlists off the shelf on libraries with hundreds of followed
    /// albums, which is the «они не все» users kept reporting.
    /// A walk interrupted before it ended — a tab switch, a token refresh,
    /// a page that timed out on 3G — resumes from `prefetchOffset` on the
    /// next appear or pull-to-refresh, keeping the pages it already has.
    /// `force` is the only thing that starts the list over from zero.
    func load(
        force: Bool = false,
        pages: Int = LibraryPlaylistPagePolicy.prefetchPages,
        operation: (Int) async throws -> MusicPage<Playlist>
    ) async {
        guard !isLoading, force || !didFinishPrefetch else { return }
        isLoading = true
        defer { isLoading = false }
        if force {
            prefetchOffset = 0
            prefetched = []
            didFinishPrefetch = false
        }
        var collected = prefetched
        var offset = prefetchOffset
        var pending: Int? = offset > 0 ? offset : nil
        do {
            for _ in 0..<max(pages, 1) {
                let page = try await page(at: offset, using: operation)
                collected.append(contentsOf: page.items)
                prefetched = collected
                publish(collected)
                guard let next = page.nextOffset, next > offset else {
                    pending = nil
                    prefetchOffset = offset
                    break
                }
                offset = next
                pending = next
                prefetchOffset = next
            }
            // A walk stopped by the runaway guard leaves `pending` set, so
            // the shelf's own pagination carries on from there.
            nextOffset = pending
            didFinishPrefetch = true
            errorMessage = nil
        } catch is CancellationError {
            // Keep the offset so the shelf's own pagination can pick the
            // walk back up, and leave the prefetch marked unfinished so the
            // next appear resumes it from `prefetchOffset`.
            nextOffset = pending
        } catch {
            // A failed later page must not throw away the playlists that
            // already loaded: keep them and leave the offset for the
            // shelf's own pagination — and for the next appear — to retry.
            nextOffset = pending
            errorMessage = collected.isEmpty
                ? error.localizedDescription
                : nil
        }
    }

    /// One page of the walk, retried once after a transient failure.
    ///
    /// A single dropped request on a slow connection used to end the walk
    /// with whatever had landed, and nothing asked for the rest until the
    /// user pulled to refresh. One immediate retry covers the timeout that
    /// a 3G page hits most often.
    private func page(
        at offset: Int,
        using operation: (Int) async throws -> MusicPage<Playlist>
    ) async throws -> MusicPage<Playlist> {
        do {
            return try await operation(offset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(
                nanoseconds: UInt64(
                    LibraryPlaylistPagePolicy.retryDelay * 1_000_000_000
                )
            )
            return try await operation(offset)
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
            prefetched += page.items
            // Carry the resume point forward: an unfinished prefetch that
            // woke up later would otherwise re-request the pages the shelf
            // has already scrolled through.
            prefetchOffset = max(prefetchOffset, page.nextOffset ?? offset)
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
        // The walk's own copy has to forget it too, or a resumed prefetch
        // publishes the deleted playlist back onto the shelf.
        prefetched.removeAll {
            $0.libraryIdentity == playlist.libraryIdentity
        }
    }

    private func publish(_ collected: [Playlist]) {
        let normalized = LibraryPlaylistShelfPolicy.normalized(
            collected,
            ownerID: ownerID
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
