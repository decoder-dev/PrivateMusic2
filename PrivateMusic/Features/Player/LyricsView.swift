import SwiftUI
import UIKit

struct LyricsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(PlaybackProgressModel.self) private var progress
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let track: Track
    private let initialLyrics: Lyrics?
    @State private var lyrics: Lyrics?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var copiedLineID: String?
    @State private var copiedFeedbackID = UUID()
    @State private var activeLineIndex = 0
    @State private var followsPlayback = true
    @State private var reloadID = UUID()

    init(track: Track, initialLyrics: Lyrics? = nil) {
        self.track = track
        self.initialLyrics = initialLyrics
        _lyrics = State(initialValue: initialLyrics)
        _isLoading = State(initialValue: initialLyrics == nil)
    }

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
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            source(lyrics)
                        }
                        .padding(.horizontal, PremiumLayout.screenPadding)
                        .padding(.vertical, 24)
                    }
                } else {
                    VStack(spacing: 18) {
                        EmptyStateView(
                            title: "lyrics_unavailable",
                            systemImage: "quote.bubble",
                            description: errorMessage
                                ?? "no_lyrics_were_found_for_this_track",
                            descriptionIsLocalizedKey: errorMessage == nil
                        )
                        geniusLink(title: "find_lyrics_on_genius")
                        if errorMessage != nil {
                            Button(L10n.text("action.retry")) {
                                reloadID = UUID()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeBackground())
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let lyrics, !lyrics.lines.isEmpty {
                        Button {
                            followsPlayback.toggle()
                        } label: {
                            Label(
                                L10n.text(followsPlayback ? "lyrics.pause_follow" : "lyrics.resume_follow"),
                                systemImage: followsPlayback ? "pause.circle" : "location.circle"
                            )
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("done")) { dismiss() }
                }
            }
        }
        .task(id: reloadID) {
            if initialLyrics == nil { await load() }
        }
        .task(id: copiedFeedbackID) {
            guard copiedLineID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                copiedLineID = nil
            } catch { return }
        }
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
                            guard player.currentTrack?.id == track.id else { return }
                            player.seek(to: line.time)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.text)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(
                                        isActive
                                            ? AnyShapeStyle(settings.accent)
                                            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                    )
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if copiedLineID == line.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44, alignment: .leading)
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
                .padding(.horizontal, PremiumLayout.screenPadding)
                .padding(.vertical, 40)
            }
            .onAppear {
                activeLineIndex = resolvedActiveLineIndex(in: lyrics)
                scrollToActiveLine(in: lyrics, proxy: proxy)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in
                    followsPlayback = false
                }
            )
            .onChange(of: progress.elapsedTime) { _ in
                let next = resolvedActiveLineIndex(in: lyrics)
                guard next != activeLineIndex else { return }
                activeLineIndex = next
            }
            .onChange(of: activeLineIndex) { _ in
                guard followsPlayback else { return }
                scrollToActiveLine(in: lyrics, proxy: proxy)
            }
            .onChange(of: followsPlayback) { follows in
                guard follows else { return }
                scrollToActiveLine(in: lyrics, proxy: proxy)
            }
        }
    }

    private func scrollToActiveLine(in lyrics: Lyrics, proxy: ScrollViewProxy) {
        guard lyrics.lines.indices.contains(activeLineIndex) else { return }
        let id = lyrics.lines[activeLineIndex].id
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: .center)
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
        }
        .buttonStyle(PremiumProminentButtonStyle())
    }

    private func resolvedActiveLineIndex(in lyrics: Lyrics) -> Int {
        let elapsed = player.currentTrack?.id == track.id
            ? progress.elapsedTime
            : 0
        return lyrics.lines.lastIndex { $0.time <= elapsed } ?? -1
    }

    private func copy(_ line: LyricLine) {
        UIPasteboard.general.string = line.text
        copiedLineID = line.id
        copiedFeedbackID = UUID()
        Haptics.selection()
        UIAccessibility.post(
            notification: .announcement,
            argument: L10n.text("line_copied")
        )
    }

    private func load() async {
        let account = sessionStore.resolvedOfflineAccountID
        if let saved = environment.savedLyricsStore.lyrics(for: track) { lyrics = saved }
        isLoading = lyrics == nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded: Lyrics
            if sessionStore.accessToken != nil {
                loaded = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.lyrics(for: track, accessToken: token)
                }
            } else {
                loaded = try await PublicLyricsService().lyrics(for: track)
            }
            try Task.checkCancellation()
            guard account == sessionStore.resolvedOfflineAccountID else { return }
            lyrics = loaded
            environment.savedLyricsStore.save(loaded, for: track)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if lyrics == nil { errorMessage = error.localizedDescription }
        }
    }
}
