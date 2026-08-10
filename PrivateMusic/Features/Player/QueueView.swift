import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var history: ListeningHistoryStore
    @Environment(\.dismiss) private var dismiss

    private var isMixQueue: Bool {
        if case .mix = player.queueSource { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    EmptyStateView(
                        title: "Очередь пуста",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: "Выберите трек, чтобы начать воспроизведение."
                    )
                } else {
                    List {
                        if isMixQueue {
                            Section {
                                Picker(
                                    L10n.text("Радио микса"),
                                    selection: Binding(
                                        get: { player.mixRadioMode },
                                        set: { mode in
                                            let artists = Set(
                                                history.entries.prefix(40)
                                                    .map(\.track.artist)
                                            )
                                            player.rerankUpcomingMix(
                                                mode: mode,
                                                historyArtists: artists
                                            )
                                        }
                                    )
                                ) {
                                    ForEach(MixRadioMode.allCases) { mode in
                                        Text(mode.compactTitle).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .listRowBackground(Color.clear)
                            } header: {
                                Text(L10n.text("Радио микса"))
                            } footer: {
                                Text(
                                    L10n.text(
                                        "Разбавляет очередь; «Ближе к треку» и «Больше новизны» "
                                            + "подтягивают рекомендации VK"
                                    )
                                )
                            }
                        }
                        if let index = player.currentIndex {
                            Text(
                                L10n.format(
                                    "Трек %d из %d",
                                    index + 1,
                                    player.queue.count
                                )
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        ForEach(
                            Array(player.queue.enumerated()),
                            id: \.offset
                        ) { index, track in
                            Button {
                                player.jump(to: index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncArtwork(
                                        url: track.artworkURL,
                                        size: 48
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let title = usableMetadata(track.title) {
                                            Text(title)
                                                .font(
                                                    .subheadline.weight(.semibold)
                                                )
                                                .lineLimit(1)
                                        }
                                        if let artist = usableMetadata(track.artist) {
                                            Text(artist)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    LikedTrackBadge(track: track)
                                    if index == player.currentIndex {
                                        PlaybackIndicatorView(
                                            isPlaying: player.isPlaying
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(accessibilityLabel(for: track))
                            .modifier(
                                CurrentQueueItemAccessibilityValueModifier(
                                    isCurrent: index == player.currentIndex
                                )
                            )
                            .accessibilityHint(
                                L10n.text("Воспроизвести из очереди")
                            )
                            .accessibilityAddTraits(
                                index == player.currentIndex
                                    ? .isSelected
                                    : []
                            )
                            .accessibilityAction(
                                named: L10n.text("Удалить из очереди")
                            ) {
                                removeFromQueue(at: index)
                            }
                            .swipeActions(
                                edge: .trailing,
                                allowsFullSwipe: true
                            ) {
                                Button(role: .destructive) {
                                    removeFromQueue(at: index)
                                } label: {
                                    Label(
                                        L10n.text("Удалить из очереди"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ThemeBackground())
            .navigationTitle("Очередь")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func removeFromQueue(at index: Int) {
        Haptics.selection()
        player.removeFromQueue(at: index)
        if player.queue.isEmpty {
            dismiss()
        }
    }

    private func accessibilityLabel(for track: Track) -> String {
        let metadata = [
            usableMetadata(track.title),
            usableMetadata(track.artist)
        ]
            .compactMap { $0 }
            .joined(separator: " — ")
        return metadata.isEmpty ? L10n.text("Трек") : metadata
    }

    private func usableMetadata(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CurrentQueueItemAccessibilityValueModifier: ViewModifier {
    let isCurrent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCurrent {
            content.accessibilityValue(L10n.text("Сейчас играет"))
        } else {
            content
        }
    }
}
