import SwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
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
        .task { await load() }
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
                    "Импортировано из \(playlist.source.title)",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(playlist.count) треков")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeBackground())
        .premiumAppear()
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
        guard let token = sessionStore.accessToken else { return }
        await model.load(
            playlist: playlist,
            service: environment.musicService,
            accessToken: token,
            force: force
        )
    }

    private func loadMore() async {
        guard let token = sessionStore.accessToken else { return }
        await model.loadMore(
            playlist: playlist,
            service: environment.musicService,
            accessToken: token
        )
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
        playlist: Playlist,
        service: any MusicService,
        accessToken: String,
        force: Bool = false
    ) async {
        guard !isLoading, force || tracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.playlistTracks(
                playlist,
                accessToken: accessToken,
                offset: 0,
                count: 100
            )
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
        playlist: Playlist,
        service: any MusicService,
        accessToken: String
    ) async {
        guard !isLoading,
              !isLoadingMore,
              let offset = nextOffset else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.playlistTracks(
                playlist,
                accessToken: accessToken,
                offset: offset,
                count: 100
            )
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
