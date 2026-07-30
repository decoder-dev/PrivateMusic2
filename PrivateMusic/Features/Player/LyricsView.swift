import SwiftUI
import UIKit

struct LyricsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    let track: Track
    @State private var lyrics: Lyrics?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var copiedLineID: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загружаем текст…")
                } else if let lyrics, !lyrics.lines.isEmpty {
                    syncedLyrics(lyrics)
                } else if let lyrics {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(lyrics.text)
                                .font(.title3)
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            source(lyrics)
                        }
                        .padding()
                    }
                } else {
                    VStack(spacing: 18) {
                        EmptyStateView(
                            title: "Текст недоступен",
                            systemImage: "quote.bubble",
                            description: errorMessage
                                ?? "Для этого трека текст не найден."
                        )
                        geniusLink(title: "Найти текст на Genius")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeBackground())
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private func syncedLyrics(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) {
                        index, line in
                        Button {
                            player.seek(to: line.time)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.text)
                                    .font(
                                        index == activeLineIndex(in: lyrics)
                                            ? .title2.weight(.bold)
                                            : .title3.weight(.semibold)
                                    )
                                    .foregroundStyle(
                                        index == activeLineIndex(in: lyrics)
                                            ? .primary
                                            : .secondary
                                    )
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if copiedLineID == line.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .onLongPressGesture {
                            UIPasteboard.general.string = line.text
                            copiedLineID = line.id
                            Haptics.selection()
                        }
                    }
                    source(lyrics).padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 40)
            }
            .onChange(of: activeLineIndex(in: lyrics)) { index in
                guard lyrics.lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(
                        lyrics.lines[index].id,
                        anchor: .center
                    )
                }
            }
        }
    }

    private func source(_ lyrics: Lyrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("Источник: %@", lyrics.source))
                .font(.caption)
                .foregroundStyle(.tertiary)
            geniusLink(
                title: lyrics.source == "Genius"
                    ? "Открыть оригинал на Genius"
                    : "Проверить текст на Genius",
                destination: lyrics.sourceURL
            )
        }
    }

    private func geniusLink(
        title: String,
        destination: URL? = nil
    ) -> some View {
        Link(
            destination: destination
                ?? GeniusLyricsService.searchPageURL(for: track)
        ) {
            Label {
                Text(L10n.text(title))
            } icon: {
                Image(systemName: "arrow.up.right")
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(
                    Color(red: 1, green: 0.98, blue: 0.18),
                    in: Capsule()
                )
        }
        .buttonStyle(PremiumPressStyle())
    }

    private func activeLineIndex(in lyrics: Lyrics) -> Int {
        let elapsed = player.currentTrack?.id == track.id
            ? player.elapsedTime
            : 0
        return lyrics.lines.lastIndex { $0.time <= elapsed } ?? 0
    }

    private func load() async {
        guard sessionStore.accessToken != nil else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            lyrics = try await environment.withAuthorizedToken { token in
                try await environment.musicService.lyrics(
                    for: track,
                    accessToken: token
                )
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
