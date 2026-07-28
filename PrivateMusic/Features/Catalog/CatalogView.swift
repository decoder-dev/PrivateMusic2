import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var recommendations: [Track] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && recommendations.isEmpty && playlists.isEmpty {
                ProgressView("Загружаем рекомендации…")
            } else if let errorMessage,
                      recommendations.isEmpty,
                      playlists.isEmpty {
                EmptyStateView(
                    title: "Каталог недоступен",
                    systemImage: "sparkles",
                    description: errorMessage
                )
            } else {
                List {
                    if !playlists.isEmpty {
                        Section("Ваши плейлисты") {
                            ForEach(playlists.prefix(8)) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(playlist: playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        AsyncArtwork(
                                            url: playlist.artworkURL,
                                            size: 54
                                        )
                                        VStack(alignment: .leading) {
                                            Text(playlist.title)
                                                .font(.headline)
                                            Text(
                                                "\(playlist.count) треков"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }

                    if !recommendations.isEmpty {
                        Section("Рекомендации для вас") {
                            ForEach(recommendations) { track in
                                TrackRow(
                                    track: track,
                                    queue: recommendations
                                )
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Главная")
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken,
              force || recommendations.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let tracks = environment.musicService.recommendations(
                accessToken: token
            )
            async let playlistPage = environment.musicService.playlists(
                accessToken: token,
                offset: 0,
                count: 30
            )
            let loaded = try await (tracks, playlistPage)
            recommendations = loaded.0
            playlists = loaded.1.items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
