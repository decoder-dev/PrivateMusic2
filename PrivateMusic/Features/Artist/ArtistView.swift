import SwiftUI

struct ArtistView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    let artist: String
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загружаем исполнителя…")
                } else if let errorMessage, tracks.isEmpty {
                    EmptyStateView(
                        title: "Исполнитель недоступен",
                        systemImage: "person.wave.2",
                        description: errorMessage
                    )
                } else {
                    List {
                        Section {
                            ForEach(tracks) { track in
                                TrackRow(track: track, queue: tracks)
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 10) {
                                AsyncArtwork(
                                    url: tracks.first?.artworkURL,
                                    size: 104
                                )
                                Text(artist)
                                    .font(.largeTitle.bold())
                                Text("Популярные треки")
                                    .foregroundStyle(.secondary)
                            }
                            .textCase(nil)
                            .padding(.bottom, 8)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ThemeBackground())
            .navigationTitle("Исполнитель")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private func load() async {
        guard let token = sessionStore.accessToken else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            let page = try await environment.musicService.search(
                query: artist,
                accessToken: token,
                offset: 0,
                count: 100
            )
            tracks = page.items.filter {
                $0.artist.localizedCaseInsensitiveContains(artist)
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
