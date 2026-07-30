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
                                        size: 46
                                    )
                                    VStack(alignment: .leading) {
                                        Text(track.title)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if index == player.currentIndex {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(.tint)
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
}
