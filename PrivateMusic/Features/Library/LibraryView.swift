import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    /// Highlight only: observing `AudioPlayer` would rebuild the library
    /// list on every buffering / duration tick. Actions go through
    /// `environment.player`.
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(OfflineTrackStore.self) private var offlineStore
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(PinnedMixStore.self) private var pinnedMixStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let offlinePlaylists =
        OfflinePlaylistStore.shared
    @State private var tracks = TrackCollectionViewModel(source: .library)
    @State private var playlists = PlaylistLibraryViewModel()
    @State private var trackSearchQuery = ""
    @State private var showingEditor = false
    @State private var pendingCellularDownload: Track?
    @State private var sharingTrack: Track?
    @State private var loadingPlayAlbumID: String?
    @State private var loadingPlayPlaylistID: Playlist.ID?
    @State private var playbackErrorMessage: String?
    @State private var playlistPendingDeletion: Playlist?
    @State private var playlistDeleteErrorMessage: String?
    /// Row `onAppear` fires in bursts while scrolling. Holding the in-flight
    /// page request keeps a burst from queueing a dozen identical loads.
    @State private var paginationTask: Task<Void, Never>?
    @State private var playlistPaginationTask: Task<Void, Never>?
    @State private var addedTrackReloadTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                // Zero-width proposals (some previews) must not produce
                // empty frames — fall back to a compact-phone width.
                let shelfWidth = geometry.size.width > 0
                    ? geometry.size.width
                    : 390
            ScrollView {
                // Section gaps are per-section padding rather than stack
                // spacing: the track rows share this stack (a nested lazy
                // stack recycles them out of order), so stack spacing would
                // also push every row and divider 24pt apart.
                LazyVStack(alignment: .leading, spacing: 0) {
                    listenLaterSection

                    if playlists.isLoading && playlists.playlists.isEmpty {
                        playlistSkeleton(width: shelfWidth)
                            .librarySectionSpacing()
                    } else if !playlists.playlists.isEmpty {
                        playlistShelf(width: shelfWidth)
                            .librarySectionSpacing()
                    }
                    if !likedAlbumsStore.albums.isEmpty {
                        albumShelf(width: shelfWidth)
                            .librarySectionSpacing()
                    }

                    HStack(spacing: 12) {
                        Text(L10n.text("library.tracks"))
                            .font(.title2.weight(.bold))
                        Spacer()
                        Text("\(tracks.totalCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        shuffleLibraryButton
                    }
                    .padding(.bottom, LibraryShelfMetrics.headerSpacing)

                    if tracks.isLoading && tracks.tracks.isEmpty {
                        trackSkeleton
                    } else if let error = tracks.errorMessage,
                              tracks.tracks.isEmpty {
                        VStack(spacing: 14) {
                            EmptyStateView(
                                title: "could_not_load_tracks",
                                systemImage: "wifi.exclamationmark",
                                description: error,
                                descriptionIsLocalizedKey: false
                            )
                            Button(L10n.text("action.retry")) {
                                Task { await loadTracks(force: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(minHeight: 260)
                    } else if tracks.tracks.isEmpty {
                        EmptyStateView(
                            title: "your_library_is_empty",
                            systemImage: "music.note",
                            description: "tracks_added_to_your_vk_library_will_appear_here"
                        )
                        .frame(minHeight: 260)
                    } else if filteredTracks.isEmpty {
                        EmptyStateView(
                            title: "no_results",
                            systemImage: "magnifyingglass",
                            description: "try_changing_your_query"
                        )
                        .frame(minHeight: 220)
                        .premiumAppear()
                    } else {
                        // Keep tracks in the same LazyVStack as the shelves —
                        // a nested LazyVStack inside ScrollView recycles rows
                        // out of order and looks like a scrambled library.
                        ForEach(
                            Array(filteredTracks.enumerated()),
                            id: \.element.id
                        ) { index, track in
                            libraryRow(track)
                                .onAppear {
                                    loadMoreIfNeeded(after: track)
                                }
                            if index < filteredTracks.count - 1 {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                }
                .id(MainTabScrollDestination.library)
                .padding(.horizontal, 16)
                // The always-visible search drawer sits directly above the
                // first section — without this the playlist shelf is jammed
                // under the header.
                .padding(.top, LibraryShelfMetrics.contentTopPadding)
            }
            .clearsMiniPlayer()
            .onChange(of: scrollCoordinator.request) { _, request in
                guard request?.destination == .library else { return }
                if reduceMotion {
                    proxy.scrollTo(MainTabScrollDestination.library, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo(
                            MainTabScrollDestination.library,
                            anchor: .top
                        )
                    }
                }
            }
            }
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("tab.library"))
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .searchable(
            text: $trackSearchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: L10n.text("track_or_artist")
        )
        .trackShareSheet(track: $sharingTrack)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                    if OfflineDownloadsFeature.showsControls,
                       !environment.isShareSessionActive {
                        NavigationLink {
                            OfflineDownloadsView()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .frame(width: 24, height: 24)
                                .overlay(alignment: .topTrailing) {
                                    if isOfflineActivityActive {
                                        ProgressView()
                                            .controlSize(.mini)
                                            .offset(x: 3, y: -3)
                                    } else if offlineStore
                                        .downloadedTrackCount > 0 {
                                        Text(
                                            "\(min(validDownloadCount, 99))"
                                        )
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule()
                                                .fill(settings.theme.accent)
                                        )
                                        .offset(x: 3, y: -3)
                                    }
                                }
                        }
                        .accessibilityLabel(L10n.text("downloads"))
                    }
                    NavigationLink {
                        ListeningHistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel(L10n.text("listening_history"))
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.text("new_playlist"))
                }
                .tint(.primary)
            }
        }
        .sheet(isPresented: $showingEditor) {
            PlaylistEditorView(playlist: nil) {
                Task { await load(force: true) }
            }
        }
        .alert(
            L10n.text("download_over_cellular"),
            isPresented: Binding(
                get: { pendingCellularDownload != nil },
                set: { if !$0 { pendingCellularDownload = nil } }
            )
        ) {
            Button(L10n.text("download_2")) {
                if let track = pendingCellularDownload {
                    pendingCellularDownload = nil
                    performDownload(track)
                }
            }
            Button(L10n.text("action.cancel"), role: .cancel) {
                pendingCellularDownload = nil
            }
        } message: {
            Text(
                L10n.text("you_are_on_a_cellular_network_downloading_may_use_mobile_data")
            )
        }
        .alert(L10n.text("could_not_start_playback"),
            isPresented: Binding(
                get: { playbackErrorMessage != nil },
                set: { if !$0 { playbackErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(playbackErrorMessage ?? "")
        }
        .task(id: sessionStore.accessToken) {
            await load(force: true)
        }
        .refreshable { await load(force: true) }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MusicLibraryEvents.didAddTrack
            )
        ) { notification in
            guard let track = notification.userInfo?[
                MusicLibraryEvents.trackKey
            ] as? Track else {
                return
            }
            tracks.insertAdded(track)
            libraryStore.markAdded(source: track, stored: track)
            // Adding several tracks in a row posts several notifications.
            // Coalesce them into one reload instead of one per track.
            addedTrackReloadTask?.cancel()
            addedTrackReloadTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await loadTracks(force: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MusicLibraryEvents.didRemoveTrack
            )
        ) { notification in
            guard let track = notification.userInfo?[
                MusicLibraryEvents.trackKey
            ] as? Track else {
                return
            }
            tracks.removeLocally(track)
            libraryStore.markRemoved(track)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .likedAlbumsDidChange)
        ) { _ in
            Task { await loadAlbums() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MusicLibraryEvents.didChangePlaylists
            )
        ) { notification in
            if let playlist = notification.userInfo?[
                MusicLibraryEvents.playlistKey
            ] as? Playlist {
                playlists.removeLocally(playlist)
            }
            Task { await reloadPlaylists(force: true) }
        }
        .confirmationDialog(
            playlistDeleteConfirmationTitle,
            isPresented: Binding(
                get: { playlistPendingDeletion != nil },
                set: { if !$0 { playlistPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let playlist = playlistPendingDeletion {
                Button(
                    playlistDeleteActionTitle(for: playlist),
                    role: .destructive
                ) {
                    Task { await deletePlaylist(playlist) }
                }
            }
            Button(L10n.text("action.cancel"), role: .cancel) {
                playlistPendingDeletion = nil
            }
        } message: {
            if let playlist = playlistPendingDeletion {
                Text(playlistDeleteConfirmationMessage(for: playlist))
            }
        }
        .alert(
            L10n.text("couldn_t_delete_playlist"),
            isPresented: Binding(
                get: { playlistDeleteErrorMessage != nil },
                set: { if !$0 { playlistDeleteErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(playlistDeleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var listenLaterSection: some View {
        if let pin = pinnedMixStore.pin, !pin.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("listen_later"))
                    .font(.title2.weight(.bold))
                Button {
                    resumePinned(pin)
                } label: {
                    HStack(spacing: 14) {
                        AsyncArtwork(url: pin.artworkURL, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pin.mixTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(
                                L10n.format(
                                    "d0_tracks_resume",
                                    pin.tracks.count
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                            .foregroundStyle(.primary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                        .fill(.primary.opacity(0.06))
                    )
                }
                .buttonStyle(PremiumPressStyle())
                .contextMenu {
                    Button {
                        resumePinned(pin)
                    } label: {
                        Label(L10n.text("resume"), systemImage: "play.fill")
                    }
                    Button(role: .destructive) {
                        pinnedMixStore.clear()
                    } label: {
                        Label(L10n.text("remove"), systemImage: "bookmark.slash")
                    }
                }
            }
            .librarySectionSpacing()
        }
    }

    private func resumePinned(_ pin: PinnedMixSnapshot) {
        let mix = pin.mix
        if mix.id == MusicMix.common.id {
            let stream = SelenaRecommendationCursor(
                seedTracks: pin.tracks,
                knownTracks: pin.tracks
            )
            environment.player.resumePinned(pin) {
                try await environment.withAuthorizedToken { token in
                    try await stream.next(
                        accessToken: token,
                        musicService: environment.musicService
                    )
                }
            }
        } else {
            let cursor = MixTrackContinuationCursor(mix: mix)
            environment.player.resumePinned(pin) {
                try await environment.withAuthorizedToken { token in
                    try await cursor.next(
                        accessToken: token,
                        musicService: environment.musicService
                    )
                }
            }
        }
    }

    /// Shuffles the visible track list and nothing else.
    ///
    /// `playShuffled` is a per-collection entry point: it leaves the
    /// player's shuffle control and the persisted preference alone, so the
    /// next tap on a row still queues Медиатека in the order it is shown.
    ///
    /// Spelled out with `Label` rather than a bare icon: a screenshot report
    /// showed people missing an icon-only glyph next to «Треки», so the
    /// control now carries its own visible caption instead of relying on
    /// the accessibility label alone.
    private var shuffleLibraryButton: some View {
        Button {
            Haptics.selection()
            shuffleLibrary()
        } label: {
            Label(L10n.text("shuffle"), systemImage: "shuffle")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(settings.theme.accent)
        .disabled(filteredTracks.isEmpty)
        .accessibilityLabel(L10n.text("shuffle"))
        .accessibilityHint(
            L10n.text("starts_playing_tracks_in_random_order")
        )
    }

    private func shuffleLibrary() {
        let queue = filteredTracks
        guard !queue.isEmpty else { return }
        let continuation = libraryContinuation(after: queue)
        environment.player.playShuffled(
            in: queue,
            continuation: continuation?.advance,
            prefetchContinuation: continuation?.prefetch,
            source: .library
        )
    }

    /// Filters the loaded tracks list only — playlist and album shelves stay
    /// untouched so they remain usable while searching.
    private var filteredTracks: [Track] {
        let normalized = trackSearchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return tracks.tracks }
        return tracks.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.artist.localizedCaseInsensitiveContains(normalized)
        }
    }

    /// Reached through `AppEnvironment` on purpose. Observing the index
    /// directly rebuilt the whole list every time a page folded into it —
    /// the heart badge on each row observes it and refreshes on its own.
    private var libraryStore: MusicLibraryStore { environment.libraryStore }

    private func isCurrent(_ track: Track) -> Bool {
        highlight.isCurrent(track.id)
    }

    private func albumQueueSource(for album: Album) -> QueueSource {
        .album(title: albumPlaybackTitle(album))
    }

    private func albumPlaybackTitle(_ album: Album) -> String {
        Album.isUsableTitle(album.title) ? album.title : L10n.text("album")
    }

    private func albumPlaybackAction(
        for album: Album
    ) -> QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: albumQueueSource(for: album),
            isPlaying: highlight.isPlaying,
            queueSource: highlight.queueSource
        )
    }

    private func performAlbumPlaybackAction(
        _ action: QueueSourcePlaybackAction,
        for album: Album
    ) {
        switch action {
        case .start:
            playAlbum(album)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func playAlbum(_ album: Album) {
        guard sessionStore.accessToken != nil else { return }
        loadingPlayAlbumID = album.id
        Task {
            defer { loadingPlayAlbumID = nil }
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.albumTracks(
                        album,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
                guard let first = page.items.first else { return }
                environment.player.play(
                    first,
                    in: page.items,
                    source: albumQueueSource(for: album)
                )
            } catch is CancellationError {
                return
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
        }
    }

    private func playlistQueueSource(for playlist: Playlist) -> QueueSource {
        .playlist(title: playlist.title)
    }

    private func playlistPlaybackAction(
        for playlist: Playlist
    ) -> QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: playlistQueueSource(for: playlist),
            isPlaying: highlight.isPlaying,
            queueSource: highlight.queueSource
        )
    }

    private func performPlaylistPlaybackAction(
        _ action: QueueSourcePlaybackAction,
        for playlist: Playlist
    ) {
        switch action {
        case .start:
            playPlaylist(playlist)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func playPlaylist(_ playlist: Playlist) {
        guard sessionStore.accessToken != nil else { return }
        loadingPlayPlaylistID = playlist.id
        Task {
            defer { loadingPlayPlaylistID = nil }
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.playlistTracks(
                        playlist,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
                guard let first = page.items.first else { return }
                environment.player.play(
                    first,
                    in: page.items,
                    source: playlistQueueSource(for: playlist)
                )
            } catch is CancellationError {
                return
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
        }
    }

    private func isOwnedPlaylist(_ playlist: Playlist) -> Bool {
        playlist.ownerID == sessionStore.session?.userID
    }

    private var playlistDeleteConfirmationTitle: String {
        guard let playlist = playlistPendingDeletion else {
            return L10n.text("delete_playlist")
        }
        return L10n.text(
            isOwnedPlaylist(playlist)
                ? "delete_playlist"
                : "remove_playlist_from_library"
        )
    }

    private func playlistDeleteActionTitle(for playlist: Playlist) -> String {
        L10n.text(
            isOwnedPlaylist(playlist)
                ? "remove_playlist"
                : "remove_from_library_2"
        )
    }

    private func playlistDeleteConfirmationMessage(
        for playlist: Playlist
    ) -> String {
        L10n.text(
            isOwnedPlaylist(playlist)
                ? "the_playlist_will_be_deleted_from_vk_this_can_t_be_undone"
                : "the_playlist_will_leave_your_library_but_stay_with_its_owner"
        )
    }

    private func deletePlaylist(_ playlist: Playlist) async {
        playlistPendingDeletion = nil
        guard sessionStore.accessToken != nil else { return }
        do {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.deletePlaylist(
                    playlist,
                    accessToken: token
                )
            }
            offlinePlaylists.remove(playlist)
            playlists.removeLocally(playlist)
            MusicLibraryEvents.postPlaylistsChanged(removed: playlist)
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            playlistDeleteErrorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Defect 12: the badge must reflect both in-flight track downloads and
    /// active playlist batches, and the counter must be file-backed.
    private var isOfflineActivityActive: Bool {
        if !offlineStore.downloadingTrackIDs.isEmpty {
            return true
        }
        return offlinePlaylists.records.values.contains {
            OfflinePlaylistStatus.status(for: $0).isActive
        }
    }

    private var validDownloadCount: Int {
        offlineStore.availableRecords.count
    }

    private var currentTrackColor: Color {
        settings.theme.accent
    }

    private func playlistShelf(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("library.playlists"))
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                // Deliberately not lazy: nested inside the library's
                // LazyVStack, a lazy row left off-screen cards
                // unmaterialized, so playlists past the first screenful
                // never appeared and the trailing card's onAppear never
                // asked for the next page.
                HStack(
                    alignment: .top,
                    spacing: LibraryShelfMetrics.cardSpacing
                ) {
                    // VK playlist ids repeat across owners, so identify cards
                    // by owner+id. Colliding ForEach ids let SwiftUI reuse one
                    // card for several playlists and drop their artwork.
                    ForEach(
                        Array(playlists.playlists.enumerated()),
                        id: \.element.libraryIdentity
                    ) { index, playlist in
                        playlistCard(
                            playlist,
                            index: index,
                            isLast: index == playlists.playlists.count - 1,
                            width: width
                        )
                    }
                }
                .padding(.vertical, LibraryShelfMetrics.shelfPadding)
            }
            // A lazy row has no intrinsic height: pin it so the cards keep
            // their artwork instead of collapsing to caption-only chips.
            .frame(height: LibraryShelfMetrics.shelfHeight(for: width))
        }
    }

    private func playlistCard(
        _ playlist: Playlist,
        index: Int,
        isLast: Bool,
        width: CGFloat
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: LibraryShelfMetrics.captionSpacing
        ) {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    PlaylistArtworkView(
                        playlist: playlist,
                        size: LibraryShelfMetrics.artworkSize(for: width)
                    )
                }
                .buttonStyle(PremiumPressStyle())

                playlistPlayChip(playlist)
            }
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(L10n.trackCount(playlist.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: LibraryShelfMetrics.captionHeight,
                    maxHeight: LibraryShelfMetrics.captionHeight,
                    alignment: .topLeading
                )
            }
            .buttonStyle(.plain)
        }
        .frame(
            width: LibraryShelfMetrics.cardWidth(for: width),
            height: LibraryShelfMetrics.cardHeight(for: width),
            alignment: .topLeading
        )
        .premiumAppear(delay: min(Double(index) * 0.025, 0.2))
        .contextMenu {
            Button {
                performPlaylistPlaybackAction(
                    playlistPlaybackAction(for: playlist),
                    for: playlist
                )
            } label: {
                Label(
                    L10n.text("listen"),
                    systemImage: "play.fill"
                )
            }
            Button(
                role: .destructive,
                action: {
                    playlistPendingDeletion = playlist
                }
            ) {
                Label(
                    playlistDeleteActionTitle(for: playlist),
                    systemImage: "trash"
                )
            }
        }
        .onAppear {
            guard isLast else { return }
            loadMorePlaylistsIfNeeded()
        }
    }

    private func playlistPlayChip(_ playlist: Playlist) -> some View {
        let action = playlistPlaybackAction(for: playlist)
        return Button {
            performPlaylistPlaybackAction(action, for: playlist)
        } label: {
            Group {
                if loadingPlayPlaylistID == playlist.id {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: action.systemImage)
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 32, height: 32)
            .background(.white, in: Circle())
        }
        .buttonStyle(PremiumPressStyle())
        .padding(8)
        .disabled(
            loadingPlayPlaylistID != nil
                && loadingPlayPlaylistID != playlist.id
        )
        .accessibilityLabel(
            L10n.text(
                action.accessibilityLabelKey(playKey: "play_playlist")
            )
        )
    }

    private func albumShelf(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("library.albums"))
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: LibraryShelfMetrics.cardSpacing
                ) {
                    ForEach(likedAlbumsStore.albums) { album in
                        albumCard(album, width: width)
                    }
                }
                .padding(.vertical, LibraryShelfMetrics.shelfPadding)
            }
            .frame(height: LibraryShelfMetrics.shelfHeight(for: width))
        }
    }

    private func albumCard(_ album: Album, width: CGFloat) -> some View {
        VStack(
            alignment: .leading,
            spacing: LibraryShelfMetrics.captionSpacing
        ) {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AsyncArtwork(
                        url: album.artworkURL,
                        size: LibraryShelfMetrics.artworkSize(for: width)
                    )
                }
                .buttonStyle(PremiumPressStyle())

                albumPlayChip(album)
            }
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        Album.isUsableTitle(album.title)
                            ? album.title
                            : L10n.text("album")
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.artistText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: LibraryShelfMetrics.captionHeight,
                    maxHeight: LibraryShelfMetrics.captionHeight,
                    alignment: .topLeading
                )
            }
            .buttonStyle(.plain)
        }
        .frame(
            width: LibraryShelfMetrics.cardWidth(for: width),
            height: LibraryShelfMetrics.cardHeight(for: width),
            alignment: .topLeading
        )
    }

    private func albumPlayChip(_ album: Album) -> some View {
        let action = albumPlaybackAction(for: album)
        return Button {
            performAlbumPlaybackAction(action, for: album)
        } label: {
            Group {
                if loadingPlayAlbumID == album.id {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: action.systemImage)
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 32, height: 32)
            .background(.white, in: Circle())
        }
        .buttonStyle(PremiumPressStyle())
        .padding(8)
        .disabled(
            loadingPlayAlbumID != nil && loadingPlayAlbumID != album.id
        )
        .accessibilityLabel(
            L10n.text(
                action.accessibilityLabelKey(playKey: "play_album")
            )
        )
    }

    private func libraryRow(_ track: Track) -> some View {
        // Photo-1 composition: art | title+artist | heart | duration | … 
        // Title column must flex; trailing cluster stays fixed so rows align.
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                performLibraryTrackPrimaryAction(track)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtwork(url: track.artworkURL, size: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        if let title = libraryUsableMetadata(track.title) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    isCurrent(track)
                                        ? currentTrackColor
                                        : Color.primary
                                )
                                .lineLimit(1)
                        }
                        if let artist = libraryUsableMetadata(track.artist) {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 8) {
                        LikedTrackBadge(track: track)
                        Text(track.duration.formattedDuration)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                        if isCurrent(track) {
                            Image(
                                systemName: highlight.isPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(currentTrackColor)
                                .frame(width: 14, alignment: .center)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(libraryRowAccessibilityLabel(track))
            .accessibilityHint(libraryRowAccessibilityHint(track))

            Menu {
                Button {
                    environment.player.playNext(track)
                } label: {
                    Label(L10n.text("play_next"), systemImage: "text.badge.plus")
                }
                Button {
                    Haptics.open()
                    sharingTrack = track
                } label: {
                    Label(L10n.text("share_audio_file"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                if OfflineDownloadsFeature.showsControls {
                    Button(
                        role: offlineStore.contains(track) ? .destructive : nil
                    ) {
                        toggleOffline(track)
                    } label: {
                        Label(
                            offlineStore.contains(track)
                                ? "remove_download"
                                : "download",
                            systemImage: offlineStore.contains(track)
                                ? "trash"
                                : "arrow.down.circle"
                        )
                    }
                    .disabled(
                        offlineStore.downloadingTrackIDs.contains(track.id)
                    )
                }
                Button(role: .destructive) {
                    guard let token = sessionStore.accessToken else { return }
                    Task {
                        if await tracks.remove(
                            track,
                            accessToken: token
                        ) {
                            libraryStore.markRemoved(track)
                        }
                    }
                } label: {
                    Label(L10n.text("action.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.text("more"))
        }
        .padding(.vertical, 6)
    }

    private func performLibraryTrackPrimaryAction(_ track: Track) {
        guard isCurrent(track) else {
            playLibraryTrack(track)
            return
        }

        if highlight.isPlaying {
            environment.player.pause()
        } else {
            environment.player.resume()
        }
    }

    /// Plays the library the way it is on screen: the queue is the visible
    /// list, in the visible order, positioned on the tapped track. Nothing
    /// here reorders or reseeds it — «они играют в разнобой» was this path
    /// inheriting a shuffle another screen had turned on, and then
    /// continuing into recommendations instead of the next library page.
    private func playLibraryTrack(_ track: Track) {
        let queue = filteredTracks.isEmpty ? tracks.tracks : filteredTracks
        let continuation = libraryContinuation(after: queue)
        environment.player.play(
            track,
            in: queue,
            continuation: continuation?.advance,
            prefetchContinuation: continuation?.prefetch,
            source: .library
        )
    }

    /// Continues in VK library order once the loaded window runs out. Nil
    /// while a search filter is active: the rest of the library does not
    /// belong behind a filtered list.
    private func libraryContinuation(
        after queue: [Track]
    ) -> (
        advance: () async throws -> [Track],
        prefetch: () async throws -> [Track]
    )? {
        guard queue.count == tracks.tracks.count,
              let offset = tracks.nextPageOffset else {
            return nil
        }
        let cursor = LibraryTrackContinuationCursor(
            startingOffset: offset,
            knownTracks: queue
        )
        // The player outlives this view, so the closure holds the
        // environment itself rather than reading the EnvironmentObject
        // wrapper later.
        let appEnvironment = environment
        let advance = {
            try await appEnvironment.withAuthorizedToken { token in
                try await cursor.next(
                    accessToken: token,
                    musicService: appEnvironment.musicService
                )
            }
        }
        let prefetch = {
            try await appEnvironment.withAuthorizedToken { token in
                try await cursor.nextLibraryPage(
                    accessToken: token,
                    musicService: appEnvironment.musicService
                )
            }
        }
        return (advance: advance, prefetch: prefetch)
    }

    private func libraryUsableMetadata(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func libraryRowAccessibilityLabel(_ track: Track) -> String {
        let metadata = [
            libraryUsableMetadata(track.title),
            libraryUsableMetadata(track.artist)
        ]
            .compactMap { $0 }
            .joined(separator: " — ")
        let duration = track.duration.formattedDuration
        guard !metadata.isEmpty else { return duration }
        return "\(metadata), \(duration)"
    }

    private func libraryRowAccessibilityHint(_ track: Track) -> String {
        guard isCurrent(track) else {
            return L10n.text("play_track")
        }
        return L10n.text(
            highlight.isPlaying ? "pause_now" : "resume_playback"
        )
    }

    private func toggleOffline(_ track: Track) {
        if offlineStore.contains(track) {
            offlineStore.remove(track)
            Haptics.selection()
            return
        }
        if networkMonitor.transport == .cellular {
            pendingCellularDownload = track
        } else {
            performDownload(track)
        }
    }

    private func performDownload(_ track: Track) {
        Task {
            do {
                try await environment.downloadForOffline(track)
                Haptics.success()
                DownloadNotifications.notifyDownloadComplete(
                    title: "\(track.artist) — \(track.title)"
                )
            } catch is CancellationError {
                return
            } catch {
                Haptics.error()
                environment.player.errorMessage = L10n.format(
                    "could_not_save_the_track_offline_0",
                    error.localizedDescription
                )
                DownloadNotifications.notifyDownloadError(
                    title: "\(track.artist) — \(track.title)"
                )
            }
        }
    }

    private func playlistSkeleton(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("library.playlists"))
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(
                    alignment: .top,
                    spacing: LibraryShelfMetrics.cardSpacing
                ) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                            .fill(.primary.opacity(0.08))
                            .frame(
                                width: LibraryShelfMetrics.cardWidth(for: width),
                                height: LibraryShelfMetrics.cardHeight(for: width)
                            )
                    }
                }
                .padding(.vertical, LibraryShelfMetrics.shelfPadding)
            }
            .frame(height: LibraryShelfMetrics.shelfHeight(for: width))
        }
        .redacted(reason: .placeholder)
    }

    private var trackSkeleton: some View {
        VStack(spacing: 14) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(
                        cornerRadius:
                            PremiumLayout.artworkRadius(for: 46),
                        style: .continuous
                    )
                        .fill(.primary.opacity(0.08))
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.primary.opacity(0.09))
                            .frame(width: 190, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.primary.opacity(0.06))
                            .frame(width: 120, height: 11)
                    }
                    Spacer()
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    /// Tracks, playlists and albums are independent VK lists. Loading them
    /// one after the other left the shelves empty until a 100-track page had
    /// finished, which is most of the stall people notice on Медиатека.
    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil else { return }
        async let loadedTracks: Void = loadTracks(force: force)
        async let loadedPlaylists: Void = reloadPlaylists(force: force)
        async let loadedAlbums: Void = loadAlbums()
        _ = await (loadedTracks, loadedPlaylists, loadedAlbums)
    }

    private func reloadPlaylists(force: Bool) async {
        playlists.configure(
            // The resolved account id, not the session field alone: a
            // session restored before the profile lands carries no user id.
            ownerID: sessionStore.resolvedOfflineAccountID
        )
        await playlists.load(force: force) { offset in
            try await playlistPage(offset: offset)
        }
    }

    private func playlistPage(offset: Int) async throws -> MusicPage<Playlist> {
        try await environment.withAuthorizedToken { token in
            try await environment.musicService.playlists(
                accessToken: token,
                offset: offset,
                count: LibraryPlaylistPagePolicy.pageSize
            )
        }
    }

    /// The Albums shelf is filled by the shared refresh the tab shell also
    /// runs, so opening Медиатека no longer repeats a ten-page walk that the
    /// app just finished.
    private func loadAlbums() async {
        await environment.refreshLikedAlbums()
    }

    private func loadTracks(force: Bool) async {
        guard sessionStore.accessToken != nil else { return }
        tracks.configure(service: environment.musicService)
        let loaded = await tracks.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.library(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
        if loaded {
            // Only fold this page in. The authoritative index comes from
            // `AppEnvironment.refreshLibraryIndex()`, which walks every
            // page — replacing it from here blanked the heart on every
            // track past the first hundred.
            libraryStore.include(tracks.tracks)
        }
    }

    private func loadMoreIfNeeded(after track: Track) {
        guard track.id == tracks.tracks.last?.id,
              sessionStore.accessToken != nil,
              paginationTask == nil else {
            return
        }
        paginationTask = Task {
            defer { paginationTask = nil }
            let loaded = await tracks.loadMore { offset in
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.library(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
            }
            if loaded {
                libraryStore.include(tracks.tracks)
            }
        }
    }

    private func loadMorePlaylistsIfNeeded() {
        guard sessionStore.accessToken != nil,
              playlistPaginationTask == nil else {
            return
        }
        playlistPaginationTask = Task {
            defer { playlistPaginationTask = nil }
            await playlists.loadMore { offset in
                try await playlistPage(offset: offset)
            }
        }
    }
}
