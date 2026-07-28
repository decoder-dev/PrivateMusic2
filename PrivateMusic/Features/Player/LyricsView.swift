import SwiftUI

struct LyricsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    let track: Track
    @State private var lyrics: Lyrics?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if isLoading {
                        ProgressView("Загружаем текст…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if let lyrics {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(lyrics.text)
                                .font(.title3)
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            Text("Источник: \(lyrics.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        EmptyStateView(
                            title: "Текст недоступен",
                            systemImage: "quote.bubble",
                            description: errorMessage
                                ?? "Для этого трека текст не найден."
                        )
                    }
                }
                .padding()
            }
            .background(ThemeBackground())
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private func load() async {
        guard let token = sessionStore.accessToken else {
            isLoading = false
            return
        }
        do {
            lyrics = try await environment.musicService.lyrics(
                for: track,
                accessToken: token
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
