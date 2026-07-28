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
                    EmptyStateView(
                        title: "Текст недоступен",
                        systemImage: "quote.bubble",
                        description: errorMessage
                            ?? "Для этого трека текст не найден."
                    )
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
        Text("Источник: \(lyrics.source)")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func activeLineIndex(in lyrics: Lyrics) -> Int {
        let elapsed = player.currentTrack?.id == track.id
            ? player.elapsedTime
            : 0
        return lyrics.lines.lastIndex { $0.time <= elapsed } ?? 0
    }

    private func load() async {
        guard let token = sessionStore.accessToken else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            lyrics = try await environment.musicService.lyrics(
                for: track,
                accessToken: token
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
