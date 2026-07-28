import SwiftUI

struct PlaylistLibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var model = PlaylistLibraryViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.playlists.isEmpty {
                ProgressView("Загружаем плейлисты…")
            } else if let error = model.errorMessage,
                      model.playlists.isEmpty {
                EmptyStateView(
                    title: "Не удалось загрузить плейлисты",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.playlists.isEmpty {
                EmptyStateView(
                    title: "Плейлистов пока нет",
                    systemImage: "rectangle.stack",
                    description: "Созданные во VK плейлисты появятся здесь."
                )
            } else {
                List(model.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncArtwork(
                                url: playlist.artworkURL,
                                size: 56
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text("\(playlist.count) треков")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken else { return }
        await model.load(
            service: environment.musicService,
            accessToken: token,
            force: force
        )
    }
}

@MainActor
private final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func load(
        service: any MusicService,
        accessToken: String,
        force: Bool = false
    ) async {
        guard !isLoading, force || playlists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await service.playlists(
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
