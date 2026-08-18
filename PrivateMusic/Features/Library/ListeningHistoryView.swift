import SwiftUI

struct ListeningHistoryView: View {
    @Environment(ListeningHistoryStore.self) private var history
    /// Playback is only triggered from here — observing `AudioPlayer` would
    /// rebuild the whole history list on every buffering / duration tick.
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var showingClearConfirmation = false
    @State private var sharingTrack: Track?
    @State private var playlistTarget: Track?

    private var filtered: [ListeningHistoryEntry] {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.track.title.localizedCaseInsensitiveContains(normalized)
                || $0.track.artist.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                EmptyStateView(
                    title: "history_is_empty",
                    systemImage: "clock.arrow.circlepath",
                    description: "tracks_you_play_will_appear_here"
                )
            } else {
                ScrollView {
                    AppGroupedSurface {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) {
                            index, entry in
                            Button {
                                play(entry)
                            } label: {
                                TrackRowContent(
                                    artworkURL: entry.track.artworkURL,
                                    title: entry.track.title,
                                    artist: entry.track.artist,
                                    showsLikedBadge: true,
                                    likedTrack: entry.track,
                                    durationText: entry.track.duration.formattedDuration
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    environment.player.playNext(entry.track)
                                } label: {
                                    Label(L10n.text("play_next"),
                                        systemImage:
                                            "text.line.first.and.arrowtriangle.forward"
                                    )
                                }
                                Button {
                                    environment.player.playLast(entry.track)
                                } label: {
                                    Label(L10n.text("play_last"),
                                        systemImage:
                                            "text.line.last.and.arrowtriangle.forward"
                                    )
                                }
                                Button {
                                    Haptics.open()
                                    sharingTrack = entry.track
                                } label: {
                                    Label(L10n.text("share_audio_file"),
                                        systemImage: "square.and.arrow.up"
                                    )
                                }
                                Button {
                                    Haptics.open()
                                    playlistTarget = entry.track
                                } label: {
                                    Label(L10n.text("add_to_playlist"),
                                        systemImage: "rectangle.stack.badge.plus"
                                    )
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    environment.player.playNext(entry.track)
                                } label: {
                                    Label(L10n.text("play_next"),
                                        systemImage: "text.badge.plus"
                                    )
                                }
                                .tint(settings.theme.accent)
                                Button {
                                    environment.player.playLast(entry.track)
                                } label: {
                                    Label(L10n.text("play_last"),
                                        systemImage:
                                            "text.line.last.and.arrowtriangle.forward"
                                    )
                                }
                                .tint(BubbleGamut.mix.color)
                                Button {
                                    playlistTarget = entry.track
                                } label: {
                                    Label(L10n.text("add_to_playlist"),
                                        systemImage: "rectangle.stack.badge.plus"
                                    )
                                }
                                .tint(BubbleGamut.mix.color)
                            }
                            .swipeActions {
                                Button {
                                    sharingTrack = entry.track
                                } label: {
                                    Label(L10n.text("share_audio_file"),
                                        systemImage: "square.and.arrow.up"
                                    )
                                }
                                .tint(BubbleGamut.warning.color)
                                Button(role: .destructive) {
                                    history.remove(entry)
                                } label: {
                                    Label(L10n.text("action.delete"), systemImage: "trash")
                                }
                            }
                            if index < filtered.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.vertical, BubbleSpacing.l)
                }
            }
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("library.history"))
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: L10n.text("track_or_artist")
        )
        .trackShareSheet(track: $sharingTrack)
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistView(track: track)
        }
        .toolbar {
            if !history.entries.isEmpty {
                Button(L10n.text("clear")) { showingClearConfirmation = true }
            }
        }
        .confirmationDialog(L10n.text("clear_all_history"),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("clear"), role: .destructive) { history.clear() }
        }
    }

    private func play(_ entry: ListeningHistoryEntry) {
        environment.player.play(
            entry.track,
            in: history.entries.map(\.track),
            source: .history
        )
    }
}
