import SwiftUI

struct ListeningHistoryView: View {
    @EnvironmentObject private var history: ListeningHistoryStore
    /// Playback is only triggered from here — observing `AudioPlayer` would
    /// rebuild the whole history list on every buffering / duration tick.
    @EnvironmentObject private var environment: AppEnvironment
    @State private var query = ""
    @State private var showingClearConfirmation = false

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
                            environment.player.play(
                                entry.track,
                                in: history.entries.map(\.track),
                                source: .history
                            )
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
                                Spacer()
                                LikedTrackBadge(track: entry.track)
                                Text(entry.playedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .swipeActions {
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
        .searchable(text: $query, prompt: "Трек или исполнитель")
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
}
