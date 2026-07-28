import SwiftUI

struct MixView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView("Готовим персональный микс…")
            } else if let errorMessage, tracks.isEmpty {
                EmptyStateView(
                    title: "Не удалось запустить микс",
                    systemImage: "sparkles",
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
                        Label("Для вас", systemImage: "sparkles")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Микс")
        .task {
            await load()
        }
        .refreshable {
            await load(force: true)
        }
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken,
              !isLoading,
              force || tracks.isEmpty else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try await environment.musicService.mixTracks(
                .common,
                accessToken: token
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
