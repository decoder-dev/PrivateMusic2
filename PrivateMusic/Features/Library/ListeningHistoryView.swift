import SwiftUI

struct ListeningHistoryView: View {
    @Environment(ListeningHistoryStore.self) private var history
    /// Playback is only triggered from here — observing `AudioPlayer` would
    /// rebuild the whole history list on every buffering / duration tick.
    @Environment(AppEnvironment.self) private var environment
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
                List {
                    ForEach(filtered) { entry in
                        Button {
                            play(entry)
                        } label: {
                            HStack(spacing: 12) {
                                AsyncArtwork(
                                    url: entry.track.artworkURL,
                                    size: 48
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.track.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(entry.track.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                LikedTrackBadge(track: entry.track)
                                    .frame(width: 18, alignment: .trailing)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
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
                            .tint(.indigo)
                            Button {
                                playlistTarget = entry.track
                            } label: {
                                Label(L10n.text("add_to_playlist"),
                                    systemImage: "rectangle.stack.badge.plus"
                                )
                            }
                            .tint(.blue)
                        }
                        .swipeActions {
                            Button {
                                sharingTrack = entry.track
                            } label: {
                                Label(L10n.text("share_audio_file"),
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .tint(.orange)
                            Button(role: .destructive) {
                                history.remove(entry)
                            } label: {
                                Label(L10n.text("action.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
