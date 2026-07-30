import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    let playlist: Playlist
    @StateObject private var model = PlaylistDetailViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.tracks.isEmpty {
                ProgressView("Загружаем треки…")
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                EmptyStateView(
                    title: "Не удалось открыть плейлист",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.tracks.isEmpty {
                VStack(spacing: 18) {
                    playlistHeader
                    EmptyStateView(
                        title: playlist.title,
                        systemImage: "music.note",
                        description: "В плейлисте пока нет доступных треков."
                    )
                }
            } else {
                List(model.tracks) { track in
                    TrackRow(track: track, queue: model.tracks)
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .top, spacing: 0) {
                    playlistHeader
                        .padding(.bottom, 8)
                }
            }
        }
        .background(ThemeBackground())
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                offlineButton
            }
        }
        .task { await load() }
        .task(id: sessionStore.session?.userID) {
            offlinePlaylists.configure(
                accountID: sessionStore.session?.userID
            )
        }
        .refreshable { await load(force: true) }
    }

    private var playlistHeader: some View {
        HStack(spacing: 14) {
            PlaylistArtworkView(playlist: playlist, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let record = offlinePlaylists.record(for: playlist),
               record.state == .downloading || record.state == .queued {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: record.progress)
                        .frame(width: 72)
                    Text(
                        L10n.format(
                            "%d из %d",
                            record.completedCount,
                            record.totalCount
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeBackground())
        .premiumAppear()
    }

    @ViewBuilder
    private var offlineButton: some View {
        switch offlinePlaylists.record(for: playlist)?.state {
        case .queued, .downloading:
            Button {
                offlinePlaylists.cancelDownload(for: playlist)
            } label: {
                Label("Отменить загрузку", systemImage: "xmark.circle")
            }
        case .available:
            Menu {
                Button(role: .destructive) {
                    offlinePlaylists.remove(playlist)
                } label: {
                    Label("Удалить плейлист", systemImage: "trash")
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
            }
        case .partial, .cancelled, .failed, .none:
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
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
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
            var known = Set(tracks.map(\.id))
            tracks.append(contentsOf: page.items.filter {
                known.insert($0.id).inserted
            })
            nextOffset = page.nextOffset
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
