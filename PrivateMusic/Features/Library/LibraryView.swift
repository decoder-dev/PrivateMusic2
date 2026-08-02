import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    @StateObject private var tracks = TrackCollectionViewModel(source: .library)
    @StateObject private var playlists = PlaylistLibraryViewModel()
    @State private var showingEditor = false
    @State private var pendingCellularDownload: Track?
    @State private var sharingTrack: Track?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if playlists.isLoading && playlists.playlists.isEmpty {
                    playlistSkeleton
                } else if !playlists.playlists.isEmpty {
                    playlistShelf
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
                } else if tracks.tracks.isEmpty {
                    EmptyStateView(
                        title: "Медиатека пуста",
                        systemImage: "music.note",
                        description: "Добавленные во VK треки появятся здесь."
                    )
                    .frame(height: 260)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.tracks.enumerated()), id: \.element.id) {
                            index, track in
                            libraryRow(track)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .onAppear {
                                    loadMoreIfNeeded(after: track)
                                }
                            if index < tracks.tracks.count - 1 {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: tracks.tracks.map(\.id))
                }
            }
            .padding(.horizontal, 16)
        }
        .background(ThemeBackground())
        .navigationTitle("Медиатека")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .trackShareSheet(track: $sharingTrack)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
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
    }

    private func isCurrent(_ track: Track) -> Bool {
        player.currentTrack?.id == track.id
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

    private var playlistShelf: some View {        VStack(alignment: .leading, spacing: 12) {
            Text("Плейлисты")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PlaylistArtworkView(
                                    playlist: playlist,
                                    size: 136
                                )
                                Text(playlist.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(L10n.trackCount(playlist.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        }
                        .buttonStyle(PremiumPressStyle())
                        .onAppear {
                            loadMorePlaylistsIfNeeded(after: playlist)
                        }
                    }
                }
            }
        }
    }

    private func libraryRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                player.play(track, in: tracks.tracks)
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
                if isCurrent(track) {
                    Image(
                        systemName: player.isPlaying
                            ? "waveform"
                            : "pause.fill"
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
                    player.playNext(track)
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
                player.errorMessage = L10n.format(
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
        await tracks.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.library(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
        libraryStore.replace(with: tracks.tracks)
        await playlists.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.playlists(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
    }

    private func loadTracks(force: Bool) async {
        guard sessionStore.accessToken != nil else { return }
        tracks.configure(service: environment.musicService)
        await tracks.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.library(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
        libraryStore.replace(with: tracks.tracks)
    }

    private func loadMoreIfNeeded(after track: Track) {
        guard track.id == tracks.tracks.last?.id,
              sessionStore.accessToken != nil else {
            return
        }
        Task {
            await tracks.loadMore { offset in
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.library(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
            }
            libraryStore.replace(with: tracks.tracks)
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
