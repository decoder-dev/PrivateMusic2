import SwiftUI

struct PlaylistLibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var model = PlaylistLibraryViewModel()
    @State private var showingEditor = false
    @State private var editingPlaylist: Playlist?

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
                    .swipeActions(edge: .trailing) {
                        if playlist.ownerID
                            == sessionStore.session?.userID {
                            Button(role: .destructive) {
                                Task {
                                    await delete(playlist)
                                }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            Button {
                                editingPlaylist = playlist
                                showingEditor = true
                            } label: {
                                Label(
                                    "Изменить",
                                    systemImage: "pencil"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                    .onAppear {
                        guard playlist.id == model.playlists.last?.id else {
                            return
                        }
                        Task { await loadMore() }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingPlaylist = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            PlaylistEditorView(playlist: editingPlaylist) {
                Task { await load(force: true) }
            }
        }
    }

    private func delete(_ playlist: Playlist) async {
        guard let token = sessionStore.accessToken else { return }
        await model.delete(
            playlist,
            service: environment.musicService,
            accessToken: token
        )
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken else { return }
        await model.load(
            service: environment.musicService,
            accessToken: token,
            force: force
        )
    }

    private func loadMore() async {
        guard let token = sessionStore.accessToken else { return }
        await model.loadMore(
            service: environment.musicService,
            accessToken: token
        )
    }
}

@MainActor
final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    private var nextOffset: Int?

    func load(
        service: any MusicService,
        accessToken: String,
        force: Bool = false
    ) async {
        guard !isLoading, force || playlists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.playlists(
                accessToken: accessToken,
                offset: 0,
                count: 100
            )
            playlists = page.items
            nextOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(
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
            let page = try await service.playlists(
                accessToken: accessToken,
                offset: offset,
                count: 100
            )
            var known = Set(playlists.map(\.id))
            playlists.append(contentsOf: page.items.filter {
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
            playlists.removeAll { $0.id == playlist.id }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
