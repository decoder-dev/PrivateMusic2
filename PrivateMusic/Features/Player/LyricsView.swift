import SwiftUI
import UIKit

struct LyricsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(PlaybackProgressModel.self) private var progress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    @State private var lyrics: Lyrics?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var copiedLineID: String?
    @State private var activeLineIndex = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.text("loading_lyrics"))
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
                            title: "lyrics_unavailable",
                            systemImage: "quote.bubble",
                            description: errorMessage
                                ?? "no_lyrics_were_found_for_this_track"
                        )
                        geniusLink(title: "find_lyrics_on_genius")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeBackground())
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        .presentationDragIndicator(.visible)
    }

    private func syncedLyrics(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) {
                        index, line in
                        let isActive = index == activeLineIndex
                        Button {
                            player.seek(to: line.time)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.text)
                                    .font(
                                        isActive
                                            ? .title2.weight(.bold)
                                            : .title3.weight(.semibold)
                                    )
                                    .foregroundStyle(
                                        isActive ? .primary : .secondary
                                    )
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if copiedLineID == line.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .accessibilityLabel(line.text)
                        .accessibilityHint(
                            L10n.text("seek_to_this_line")
                        )
                        .accessibilityAction(
                            named: Text(L10n.text("copy_line"))
                        ) {
                            copy(line)
                        }
                        .onLongPressGesture {
                            copy(line)
                        }
                    }
                    source(lyrics).padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 40)
            }
            .onAppear {
                activeLineIndex = resolvedActiveLineIndex(in: lyrics)
            }
            .onChange(of: progress.elapsedTime) { _ in
                let next = resolvedActiveLineIndex(in: lyrics)
                guard next != activeLineIndex else { return }
                activeLineIndex = next
            }
            .onChange(of: activeLineIndex) { index in
                guard lyrics.lines.indices.contains(index) else { return }
                if reduceMotion {
                    proxy.scrollTo(
                        lyrics.lines[index].id,
                        anchor: .center
                    )
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(
                            lyrics.lines[index].id,
                            anchor: .center
                        )
                    }
                }
            }
        }
    }

    private func source(_ lyrics: Lyrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("source_0", lyrics.source))
                .font(.caption)
                .foregroundStyle(.secondary)
            geniusLink(
                title: lyrics.source == "Genius"
                    ? "open_original_on_genius"
                    : "check_lyrics_on_genius",
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

    private func resolvedActiveLineIndex(in lyrics: Lyrics) -> Int {
        let elapsed = player.currentTrack?.id == track.id
            ? progress.elapsedTime
            : 0
        return lyrics.lines.lastIndex { $0.time <= elapsed } ?? 0
    }

    private func copy(_ line: LyricLine) {
        UIPasteboard.general.string = line.text
        copiedLineID = line.id
        Haptics.selection()
        UIAccessibility.post(
            notification: .announcement,
            argument: L10n.text("line_copied")
        )
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
