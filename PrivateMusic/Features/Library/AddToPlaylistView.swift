import SwiftUI

struct AddToPlaylistView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var savingPlaylistID: Playlist.ID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.text("loading_playlists"))
                } else if playlists.isEmpty {
                    EmptyStateView(
                        title: "no_available_playlists",
                        systemImage: "rectangle.stack.badge.plus",
                        description: errorMessage
                            ?? "create_a_playlist_in_your_library",
                        descriptionIsLocalizedKey: errorMessage == nil
                    )
                } else {
                    List(playlists) { playlist in
                        Button {
                            Task { await add(to: playlist) }
                        } label: {
                            HStack(spacing: 12) {
                                PlaylistArtworkView(
                                    playlist: playlist,
                                    size: 48
                                )
                                VStack(alignment: .leading) {
                                    Text(playlist.title)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(L10n.trackCount(playlist.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(playlist.source.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if savingPlaylistID == playlist.id {
                                    ProgressView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(savingPlaylistID != nil)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ThemeBackground())
            .navigationTitle(L10n.text("add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("action.close")) { dismiss() }
                }
            }
        }
        .task { await load() }
        .alert(L10n.text("could_not_add"),
            isPresented: Binding(
                get: { errorMessage != nil && !playlists.isEmpty },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard sessionStore.accessToken != nil,
              let userID = sessionStore.session?.userID else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            let page = try await environment.withAuthorizedToken { token in
                try await environment.musicService.playlists(
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
            playlists = LibraryPlaylistShelfPolicy.normalized(
                page.items.filter { $0.ownerID == userID },
                ownerID: userID
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(to playlist: Playlist) async {
        guard sessionStore.accessToken != nil else { return }
        savingPlaylistID = playlist.id
        defer { savingPlaylistID = nil }
        do {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.add(
                    track,
                    to: playlist,
                    accessToken: token
                )
            }
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
