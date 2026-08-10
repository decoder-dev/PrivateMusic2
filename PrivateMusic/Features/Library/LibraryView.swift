import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    /// Highlight only: observing `AudioPlayer` would rebuild the library
    /// list on every buffering / duration tick. Actions go through
    /// `environment.player`.
    @EnvironmentObject private var highlight: PlaybackHighlightModel
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @EnvironmentObject private var likedAlbumsStore: LikedAlbumsStore
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @EnvironmentObject private var pinnedMixStore: PinnedMixStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    @StateObject private var tracks = TrackCollectionViewModel(source: .library)
    @StateObject private var playlists = PlaylistLibraryViewModel()
    @State private var trackSearchQuery = ""
    @State private var showingEditor = false
    @State private var pendingCellularDownload: Track?
    @State private var sharingTrack: Track?
    @State private var loadingPlayAlbumID: String?
    @State private var loadingPlayPlaylistID: Int?
    @State private var playbackErrorMessage: String?
    @State private var playlistPendingDeletion: Playlist?
    @State private var playlistDeleteErrorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    listenLaterSection

                    if playlists.isLoading && playlists.playlists.isEmpty {
                        playlistSkeleton
                    } else if !playlists.playlists.isEmpty {
                        playlistShelf
                    }
                    if !likedAlbumsStore.albums.isEmpty {
                        albumShelf
                    }

                    HStack {
                        Text("Треки")
                            .font(.title2.weight(.bold))
                        Spacer()
                        Text("\(tracks.totalCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if tracks.isLoading && tracks.tracks.isEmpty {
                        trackSkeleton
                    } else if let error = tracks.errorMessage,
                              tracks.tracks.isEmpty {
                        VStack(spacing: 14) {
                            EmptyStateView(
                                title: "Не удалось загрузить треки",
                                systemImage: "wifi.exclamationmark",
                                description: error
                            )
                            Button("Повторить") {
                                Task { await loadTracks(force: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(minHeight: 260)
                    } else if tracks.tracks.isEmpty {
                        EmptyStateView(
                            title: "Медиатека пуста",
                            systemImage: "music.note",
                            description: "Добавленные во VK треки появятся здесь."
                        )
                        .frame(minHeight: 260)
                    } else if filteredTracks.isEmpty {
                        EmptyStateView(
                            title: "Ничего не найдено",
                            systemImage: "magnifyingglass",
                            description: "Попробуйте изменить запрос."
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
            }
            .onReceive(scrollCoordinator.$request) { request in
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
        .background(ThemeBackground())
        .navigationTitle("Медиатека")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .searchable(
            text: $trackSearchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Трек или исполнитель"
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
                        .accessibilityLabel(L10n.text("Загрузки"))
                    }
                    NavigationLink {
                        ListeningHistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel(L10n.text("История прослушивания"))
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.text("Новый плейлист"))
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
            L10n.text("Скачать через мобильную сеть?"),
            isPresented: Binding(
                get: { pendingCellularDownload != nil },
                set: { if !$0 { pendingCellularDownload = nil } }
            )
        ) {
            Button(L10n.text("Скачать")) {
                if let track = pendingCellularDownload {
                    pendingCellularDownload = nil
                    performDownload(track)
                }
            }
            Button(L10n.text("Отмена"), role: .cancel) {
                pendingCellularDownload = nil
            }
        } message: {
            Text(
                L10n.text(
                    "Сейчас используется мобильная сеть. "
                        + "Загрузка может потребовать трафик."
                )
            )
        }
        .alert(
            "Не удалось начать воспроизведение",
            isPresented: Binding(
                get: { playbackErrorMessage != nil },
                set: { if !$0 { playbackErrorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
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
            Task {
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
            Task {
                await loadAlbums()
                // Liked albums used to leak into the playlist shelf via
                // unfiltered getPlaylists — reload so the shelves stay split.
                await playlists.load(force: true) {
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.playlists(
                            accessToken: token,
                            offset: 0,
                            count: 100
                        )
                    }
                }
            }
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
            Task {
                await playlists.load(force: true) {
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.playlists(
                            accessToken: token,
                            offset: 0,
                            count: 100
                        )
                    }
                }
            }
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
            Button(L10n.text("Отмена"), role: .cancel) {
                playlistPendingDeletion = nil
            }
        } message: {
            if let playlist = playlistPendingDeletion {
                Text(playlistDeleteConfirmationMessage(for: playlist))
            }
        }
        .alert(
            L10n.text("Не удалось удалить плейлист"),
            isPresented: Binding(
                get: { playlistDeleteErrorMessage != nil },
                set: { if !$0 { playlistDeleteErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("ОК"), role: .cancel) {}
        } message: {
            Text(playlistDeleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var listenLaterSection: some View {
        if let pin = pinnedMixStore.pin, !pin.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Слушать позже"))
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
                                    "%d треков · продолжить",
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
                        Label("Продолжить", systemImage: "play.fill")
                    }
                    Button(role: .destructive) {
                        pinnedMixStore.clear()
                    } label: {
                        Label("Убрать", systemImage: "bookmark.slash")
                    }
                }
            }
        }
    }

    private func resumePinned(_ pin: PinnedMixSnapshot) {
        let mix = pin.mix
        environment.player.resumePinned(pin) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixTracksContinuation(
                    mix,
                    accessToken: token
                )
            }
        }
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

    private func isCurrent(_ track: Track) -> Bool {
        highlight.isCurrent(track.id)
    }

    private func albumQueueSource(for album: Album) -> QueueSource {
        .album(title: albumPlaybackTitle(album))
    }

    private func albumPlaybackTitle(_ album: Album) -> String {
        Album.isUsableTitle(album.title) ? album.title : L10n.text("Альбом")
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
            return L10n.text("Удалить плейлист?")
        }
        return L10n.text(
            isOwnedPlaylist(playlist)
                ? "Удалить плейлист?"
                : "Убрать плейлист из медиатеки?"
        )
    }

    private func playlistDeleteActionTitle(for playlist: Playlist) -> String {
        L10n.text(
            isOwnedPlaylist(playlist)
                ? "Удалить плейлист"
                : "Убрать из медиатеки"
        )
    }

    private func playlistDeleteConfirmationMessage(
        for playlist: Playlist
    ) -> String {
        L10n.text(
            isOwnedPlaylist(playlist)
                ? "Плейлист будет удалён из VK. Это действие нельзя отменить."
                : "Плейлист исчезнет из вашей медиатеки, но останется у автора."
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
        settings.theme == .dark
            ? settings.theme.accent
            : .black
    }

    private var playlistShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Плейлисты")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .bottomTrailing) {
                                NavigationLink {
                                    PlaylistDetailView(playlist: playlist)
                                } label: {
                                    PlaylistArtworkView(
                                        playlist: playlist,
                                        size: 136
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
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 136, alignment: .leading)
                        .premiumAppear(
                            delay: min(
                                Double(
                                    playlists.playlists.firstIndex(
                                        of: playlist
                                    ) ?? 0
                                ) * 0.025,
                                0.2
                            )
                        )
                        .contextMenu {
                            Button {
                                performPlaylistPlaybackAction(
                                    playlistPlaybackAction(for: playlist),
                                    for: playlist
                                )
                            } label: {
                                Label(
                                    L10n.text("Слушать"),
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
                            loadMorePlaylistsIfNeeded(after: playlist)
                        }
                    }
                }
            }
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
                action.accessibilityLabelKey(playKey: "Воспроизвести плейлист")
            )
        )
    }

    private var albumShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Альбомы")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(likedAlbumsStore.albums) { album in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .bottomTrailing) {
                                NavigationLink {
                                    AlbumDetailView(album: album)
                                } label: {
                                    AsyncArtwork(
                                        url: album.artworkURL,
                                        size: 136
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
                                            : L10n.text("Альбом")
                                    )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(album.artistText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 136, alignment: .leading)
                    }
                }
            }
        }
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
                action.accessibilityLabelKey(playKey: "Воспроизвести альбом")
            )
        )
    }

    private func libraryRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                environment.player.play(track, in: tracks.tracks)
            } label: {
                HStack(spacing: 12) {
                AsyncArtwork(url: track.artworkURL, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            isCurrent(track)
                                ? currentTrackColor
                                : Color.primary
                        )
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                LikedTrackBadge(track: track)
                Text(track.duration.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isCurrent(track) {
                    PlaybackIndicatorView(
                        isPlaying: highlight.isPlaying,
                        color: currentTrackColor
                    )
                    .font(.caption)
                    .foregroundStyle(currentTrackColor)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button {
                    environment.player.playNext(track)
                } label: {
                    Label("Играть следующим", systemImage: "text.badge.plus")
                }
                Button {
                    Haptics.open()
                    sharingTrack = track
                } label: {
                    Label(
                        "Поделиться аудиофайлом",
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
                                ? "Удалить загрузку"
                                : "Скачать офлайн",
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
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 44)
            }
        }
        .padding(.vertical, 8)
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
                    "Не удалось сохранить трек офлайн: %@",
                    error.localizedDescription
                )
                DownloadNotifications.notifyDownloadError(
                    title: "\(track.artist) — \(track.title)"
                )
            }
        }
    }

    private var playlistSkeleton: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.cardRadius,
                        style: .continuous
                    )
                        .fill(.primary.opacity(0.08))
                        .frame(width: 136, height: 168)
                }
            }
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

    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil else { return }
        tracks.configure(service: environment.musicService)
        let refreshID = libraryStore.beginRefresh()
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
            libraryStore.replace(with: tracks.tracks, refreshID: refreshID)
        }
        await playlists.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.playlists(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
        await loadAlbums()
    }

    private func loadAlbums() async {
        likedAlbumsStore.prepare(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        guard sessionStore.accessToken != nil else { return }
        let refreshID = likedAlbumsStore.beginRefresh()
        do {
            var albums: [Album] = []
            var offset = 0
            for _ in 0..<10 {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.likedAlbums(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
                albums.append(contentsOf: page.items)
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
            }
            guard !Task.isCancelled else { return }
            likedAlbumsStore.replace(with: albums, refreshID: refreshID)
        } catch {
            return
        }
    }

    private func loadTracks(force: Bool) async {
        guard sessionStore.accessToken != nil else { return }
        tracks.configure(service: environment.musicService)
        let refreshID = libraryStore.beginRefresh()
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
            libraryStore.replace(with: tracks.tracks, refreshID: refreshID)
        }
    }

    private func loadMoreIfNeeded(after track: Track) {
        guard track.id == tracks.tracks.last?.id,
              sessionStore.accessToken != nil else {
            return
        }
        Task {
            let refreshID = libraryStore.beginRefresh()
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
                libraryStore.replace(
                    with: tracks.tracks,
                    refreshID: refreshID
                )
            }
        }
    }

    private func loadMorePlaylistsIfNeeded(after playlist: Playlist) {
        guard playlist.id == playlists.playlists.last?.id,
              sessionStore.accessToken != nil else {
            return
        }
        Task {
            await playlists.loadMore { offset in
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.playlists(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
            }
        }
    }
}
