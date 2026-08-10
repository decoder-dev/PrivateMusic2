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
                    description:
                        "Созданные или сохранённые во VK плейлисты "
                        + "появятся здесь."
                )
            } else {
                List(model.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistArtworkView(
                                playlist: playlist,
                                size: 56
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(L10n.trackCount(playlist.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(
                                    L10n.format(
                                        "Из %@",
                                        playlist.source.title
                                    )
                                )
                                    .font(.caption2)
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
        guard sessionStore.accessToken != nil else { return }
        model.configure(ownerID: sessionStore.session?.userID)
        await model.load(force: force) { offset in
            try await fetchPage(offset: offset)
        }
    }

    private func loadMore() async {
        guard sessionStore.accessToken != nil else { return }
        await model.loadMore { offset in
            try await fetchPage(offset: offset)
        }
    }

    private func fetchPage(offset: Int) async throws -> MusicPage<Playlist> {
        try await environment.withAuthorizedToken { token in
            try await environment.musicService.playlists(
                accessToken: token,
                offset: offset,
                count: LibraryPlaylistPagePolicy.pageSize
            )
        }
    }
}

@MainActor
final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    private var nextOffset: Int?
    private var ownerID: Int?

    /// Lets the shelf prefer the copy of a duplicated system playlist that
    /// the signed-in user actually owns.
    func configure(ownerID: Int?) {
        self.ownerID = ownerID
    }

    /// Loads the opening pages of the playlist list. VK mixes followed
    /// albums into `audio.getPlaylists`, so a single page can decode into
    /// only a handful of playlists — the shelf pulls several pages up front
    /// and publishes each one as it lands.
    func load(
        force: Bool = false,
        pages: Int = LibraryPlaylistPagePolicy.prefetchPages,
        operation: (Int) async throws -> MusicPage<Playlist>
    ) async {
        guard !isLoading, force || playlists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var collected: [Playlist] = []
        var offset = 0
        var pending: Int?
        do {
            for _ in 0..<max(pages, 1) {
                let page = try await operation(offset)
                collected.append(contentsOf: page.items)
                playlists = LibraryPlaylistShelfPolicy.normalized(
                    collected,
                    ownerID: ownerID
                )
                guard let next = page.nextOffset, next > offset else {
                    pending = nil
                    break
                }
                offset = next
                pending = next
            }
            nextOffset = pending
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            // A failed later page must not throw away the playlists that
            // already loaded: keep them and leave the offset for the
            // shelf's own pagination to retry.
            nextOffset = pending
            errorMessage = collected.isEmpty
                ? error.localizedDescription
                : nil
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Playlist>
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
            playlists = LibraryPlaylistShelfPolicy.normalized(
                playlists + page.items,
                ownerID: ownerID
            )
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
            removeLocally(playlist)
            errorMessage = nil
            MusicLibraryEvents.postPlaylistsChanged(removed: playlist)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeLocally(_ playlist: Playlist) {
        playlists.removeAll { $0.libraryIdentity == playlist.libraryIdentity }
    }
}
