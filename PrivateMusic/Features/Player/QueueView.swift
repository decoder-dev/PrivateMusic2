import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

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
                            id: \.element.id
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
                                        Text(track.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
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
                            .accessibilityLabel(
                                L10n.format(
                                    "%@ — %@",
                                    track.title,
                                    track.artist
                                )
                            )
                            .accessibilityValue(
                                index == player.currentIndex
                                    ? L10n.text("Сейчас играет")
                                    : ""
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
}
