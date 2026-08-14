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
                ProgressView(L10n.text("loading_playlists"))
            } else if let error = model.errorMessage,
                      model.playlists.isEmpty {
                EmptyStateView(
                    title: "could_not_load_playlists",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.playlists.isEmpty {
                EmptyStateView(
                    title: "no_playlists_yet",
                    systemImage: "rectangle.stack",
                    description:
                        "vk_playlists_will_appear_here"
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
                                        "from_0",
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
                                Label(L10n.text("action.delete"), systemImage: "trash")
                            }
                            Button {
                                editingPlaylist = playlist
                                showingEditor = true
                            } label: {
                                Label(L10n.text("edit"),
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
        model.configure(ownerID: sessionStore.resolvedOfflineAccountID)
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