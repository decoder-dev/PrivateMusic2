import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    let playlist: Playlist
    @StateObject private var model = PlaylistDetailViewModel()
    @State private var showsNavTitle = false
    @State private var showsDeleteConfirmation = false
    @State private var isDeletingPlaylist = false
    @State private var deleteErrorMessage: String?

    var body: some View {
        Group {
            if model.tracks.isEmpty && (!model.hasLoaded || model.isLoading) {
                ProgressView(L10n.text("Загружаем треки…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                EmptyStateView(
                    title: "Не удалось открыть плейлист",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.hasLoaded && model.tracks.isEmpty {
                EmptyStateView(
                    title: playlist.title,
                    systemImage: "music.note",
                    description: "В плейлисте пока нет доступных треков."
                )
            } else {
                playlistList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
        .collapsingInlineNavigationTitle(
            playlist.title,
            isVisible: $showsNavTitle
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if OfflineDownloadsFeature.showsControls,
                   !model.tracks.isEmpty {
                    offlineButton
                }
                if canManagePlaylist {
                    Menu {
                        Button(
                            role: .destructive,
                            action: { showsDeleteConfirmation = true }
                        ) {
                            Label(
                                deleteActionTitle,
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isDeletingPlaylist)
                    .accessibilityLabel(L10n.text("Действия с плейлистом"))
                }
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteActionTitle, role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button(L10n.text("Отмена"), role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            L10n.text("Не удалось удалить плейлист"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("ОК"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .task { await load() }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            offlinePlaylists.configure(
                accountID: sessionStore.resolvedOfflineAccountID
            )
        }
        .refreshable { await load(force: true) }
    }

    private var isOwnedPlaylist: Bool {
        playlist.ownerID == sessionStore.session?.userID
    }

    /// Owned playlists can be deleted; followed ones use the same VK method
    /// to leave the library.
    private var canManagePlaylist: Bool {
        sessionStore.accessToken != nil
    }

    private var deleteActionTitle: String {
        L10n.text(
            isOwnedPlaylist
                ? "Удалить плейлист"
                : "Убрать из медиатеки"
        )
    }

    private var deleteConfirmationTitle: String {
        L10n.text(
            isOwnedPlaylist
                ? "Удалить плейлист?"
                : "Убрать плейлист из медиатеки?"
        )
    }

    private var deleteConfirmationMessage: String {
        L10n.text(
            isOwnedPlaylist
                ? "Плейлист будет удалён из VK. Это действие нельзя отменить."
                : "Плейлист исчезнет из вашей медиатеки, но останется у автора."
        )
    }

    private var playlistList: some View {
        List {
            Section {
                playlistHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.tracks) { track in
                TrackRow(
                    track: track,
                    queue: model.tracks,
                    source: .playlist(title: playlist.title)
                )
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing) {
                    if playlist.ownerID
                        == sessionStore.session?.userID {
                        Button(role: .destructive) {
                            Task {
                                await remove(track)
                            }
                        } label: {
                            Label("Убрать", systemImage: "minus")
                        }
                    }
                }
                .onAppear {
                    guard track.id == model.tracks.last?.id else {
                        return
                    }
                    Task { await loadMore() }
                }
            }
            if !model.tracks.isEmpty, let error = model.errorMessage {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var playlistHeader: some View {
        VStack(spacing: 14) {
            PlaylistArtworkView(playlist: playlist, size: 190)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            VStack(spacing: 5) {
                Text(playlist.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .heroTitleScrollAnchor()
                Label(
                    L10n.format(
                        "Импортировано из %@",
                        playlist.source.title
                    ),
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(L10n.trackCount(playlist.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if OfflineDownloadsFeature.showsControls,
                   let record = offlinePlaylists.record(for: playlist) {
                    let status = OfflinePlaylistStatus.status(for: record)
                    if status.isActive {
                        VStack(spacing: 3) {
                            if let progress = status.progress {
                                ProgressView(value: progress)
                                    .frame(width: 120)
                            }
                            Text(status.localizedText ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            HStack(spacing: 12) {
                listenButton
                shuffleButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// A play icon inside a wide Label pushes the text off-center (the
    /// icon+text group is centered as a unit, but the icon's width isn't
    /// mirrored on the trailing side). Centering the text on its own and
    /// pinning the icon to the leading edge keeps "Слушать" dead-center
    /// regardless of button width.
    private var listenButtonLabel: some View {
        ZStack {
            Text(L10n.text(listenAction == .pause ? "Пауза" : "Слушать"))
                .font(.headline)
            HStack {
                Image(systemName: listenAction.systemImage)
                    .accessibilityHidden(true)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var listenButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(.glassProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        } else {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        }
    }

    private var shuffleButton: some View {
        Button(action: shufflePlaylist) {
            Image(systemName: "shuffle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(settings.theme.accent)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.borderless)
        .disabled(model.tracks.isEmpty)
        .accessibilityLabel(L10n.text("Перемешать"))
    }

    private var currentSource: QueueSource {
        .playlist(title: playlist.title)
    }

    private var listenAction: QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: currentSource,
            isPlaying: player.isPlaying,
            queueSource: player.queueSource
        )
    }

    private func toggleListen() {
        switch listenAction {
        case .start:
            playPlaylist()
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func playPlaylist() {
        guard let first = model.tracks.first else { return }
        environment.player.play(
            first,
            in: model.tracks,
            source: currentSource
        )
    }

    private func shufflePlaylist() {
        environment.player.playShuffled(
            in: model.tracks,
            source: .playlist(title: playlist.title)
        )
    }

    private enum OfflineButtonState {
        case active
        case downloaded
        case needsDownload
    }

    /// Defect 5: derived from the playlist status AND the real track files,
    /// never from stale metadata alone. If files were deleted locally the
    /// button flips back to download even when the record still says
    /// `.available`.
    private var offlineButtonState: OfflineButtonState {
        guard let record = offlinePlaylists.record(for: playlist) else {
            return .needsDownload
        }
        if OfflinePlaylistStatus.status(for: record).isActive {
            return .active
        }
        if record.state == .available || record.state == .partial {
            let missing = record.tracks.contains {
                !environment.offlineStore.contains($0)
            }
            return missing ? .needsDownload : .downloaded
        }
        return .needsDownload
    }

    @ViewBuilder
    private var offlineButton: some View {
        switch offlineButtonState {
        case .active:
            Button {
                offlinePlaylists.cancelDownload(for: playlist)
            } label: {
                Label("Отменить загрузку", systemImage: "xmark.circle")
            }
        case .downloaded:
            Menu {
                Button(role: .destructive) {
                    offlinePlaylists.remove(playlist)
                } label: {
                    Label("Удалить плейлист", systemImage: "trash")
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
        case .needsDownload:
            Button {
                startOfflineDownload()
            } label: {
                Label("Скачать плейлист", systemImage: "arrow.down.circle")
            }
        }
    }

    private func startOfflineDownload() {
        guard sessionStore.accessToken != nil else { return }
        offlinePlaylists.startDownload(
            playlist: playlist,
            fetchPage: { offset in
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.playlistTracks(
                        playlist,
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
            },
            downloadTrack: { track in
                try await environment.downloadForOffline(track)
            }
        )
    }

    private func remove(_ track: Track) async {
        guard let token = sessionStore.accessToken else { return }
        await model.remove(
            track,
            playlist: playlist,
            service: environment.musicService,
            accessToken: token
        )
    }

    private func deletePlaylist() async {
        guard !isDeletingPlaylist,
              sessionStore.accessToken != nil else { return }
        isDeletingPlaylist = true
        defer { isDeletingPlaylist = false }
        do {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.deletePlaylist(
                    playlist,
                    accessToken: token
                )
            }
            offlinePlaylists.remove(playlist)
            MusicLibraryEvents.postPlaylistsChanged(removed: playlist)
            Haptics.success()
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            deleteErrorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil else { return }
        await model.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.playlistTracks(
                    playlist,
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
    }

    private func loadMore() async {
        guard sessionStore.accessToken != nil else { return }
        await model.loadMore { offset in
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.playlistTracks(
                    playlist,
                    accessToken: token,
                    offset: offset,
                    count: 100
                )
            }
        }
    }
}

@MainActor
private final class PlaylistDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?
    private var nextOffset: Int?

    func load(
        force: Bool = false,
        operation: () async throws -> MusicPage<Track>
    ) async {
        guard !isLoading, force || tracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await operation()
            tracks = page.items
            nextOffset = page.nextOffset
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Track>
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
            // Defect 17: the offset must strictly advance, otherwise a
            // server quirk would loop the same page forever.
            guard let next = page.nextOffset, next > offset else {
                nextOffset = nil
                return
            }
            var known = Set(tracks.map(\.id))
            tracks.append(contentsOf: page.items.filter {
                known.insert($0.id).inserted
            })
            nextOffset = next
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(
        _ track: Track,
        playlist: Playlist,
        service: any MusicService,
        accessToken: String
    ) async {
        do {
            try await service.remove(
                track,
                from: playlist,
                accessToken: accessToken
            )
            tracks.removeAll { $0.id == track.id }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
