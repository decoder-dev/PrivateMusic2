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
                EmptyStateView(
                    title: playlist.title,
                    systemImage: "music.note",
                    description: "В плейлисте пока нет доступных треков."
                )
            } else {
                List(model.tracks) { track in
                    TrackRow(track: track, queue: model.tracks)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .background(Brand.background)
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load(force: true) }
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
}

@MainActor
private final class PlaylistDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

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
            tracks = try await service.playlistTracks(
                playlist,
                accessToken: accessToken,
                offset: 0,
                count: 100
            ).items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
