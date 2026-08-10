import SwiftUI

struct ListeningHistoryView: View {
    @EnvironmentObject private var history: ListeningHistoryStore
    /// Playback is only triggered from here — observing `AudioPlayer` would
    /// rebuild the whole history list on every buffering / duration tick.
    @EnvironmentObject private var environment: AppEnvironment
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
                    title: "История пуста",
                    systemImage: "clock.arrow.circlepath",
                    description: "Прослушанные треки появятся здесь."
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
                                Label(
                                    "Играть следующим",
                                    systemImage:
                                        "text.line.first.and.arrowtriangle.forward"
                                )
                            }
                            Button {
                                Haptics.open()
                                sharingTrack = entry.track
                            } label: {
                                Label(
                                    "Поделиться аудиофайлом",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            Button {
                                Haptics.open()
                                playlistTarget = entry.track
                            } label: {
                                Label(
                                    "Добавить в плейлист",
                                    systemImage: "rectangle.stack.badge.plus"
                                )
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                environment.player.playNext(entry.track)
                            } label: {
                                Label(
                                    "Играть следующим",
                                    systemImage: "text.badge.plus"
                                )
                            }
                            .tint(.indigo)
                            Button {
                                playlistTarget = entry.track
                            } label: {
                                Label(
                                    "Добавить в плейлист",
                                    systemImage: "rectangle.stack.badge.plus"
                                )
                            }
                            .tint(.blue)
                        }
                        .swipeActions {
                            Button {
                                sharingTrack = entry.track
                            } label: {
                                Label(
                                    "Поделиться аудиофайлом",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .tint(.orange)
                            Button(role: .destructive) {
                                history.remove(entry)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("История")
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Трек или исполнитель"
        )
        .trackShareSheet(track: $sharingTrack)
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistView(track: track)
        }
        .toolbar {
            if !history.entries.isEmpty {
                Button("Очистить") { showingClearConfirmation = true }
            }
        }
        .confirmationDialog(
            "Очистить всю историю?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) { history.clear() }
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
