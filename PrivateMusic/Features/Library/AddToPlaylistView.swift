import SwiftUI

struct AddToPlaylistView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var savingPlaylistID: Int?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загружаем плейлисты…")
                } else if playlists.isEmpty {
                    EmptyStateView(
                        title: "Нет своих плейлистов",
                        systemImage: "rectangle.stack.badge.plus",
                        description: errorMessage
                            ?? "Создайте плейлист в медиатеке."
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
                                    Text(L10n.trackCount(playlist.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(playlist.source.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
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
            .navigationTitle("Добавить в плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .task { await load() }
        .alert(
            "Не удалось добавить",
            isPresented: Binding(
                get: { errorMessage != nil && !playlists.isEmpty },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
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
            playlists = page.items.filter { $0.ownerID == userID }
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
