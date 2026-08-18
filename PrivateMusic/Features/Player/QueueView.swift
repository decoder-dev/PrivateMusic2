import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(ListeningHistoryStore.self) private var history
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
                        title: "queue_is_empty",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: "choose_a_track_to_start_playback"
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                            if isMixQueue {
                                AppGroupedSection(
                                    title: "mix_radio",
                                    subtitle: "diversifies_the_queue_closer_to_track_and_more_novelty_pull_vk_recommend"
                                ) {
                                    Picker(
                                        L10n.text("mix_radio"),
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
                                    .padding(.horizontal, BubbleSpacing.xs)
                                    .padding(.vertical, BubbleSpacing.xs)
                                }
                            }

                            VStack(alignment: .leading, spacing: BubbleSpacing.m) {
                                if let index = player.currentIndex {
                                    Text(
                                        L10n.format(
                                            "track_d0_of_d1",
                                            index + 1,
                                            player.queue.count
                                        )
                                    )
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                }
                                AppGroupedSurface {
                                    ForEach(
                                        Array(player.queue.enumerated()),
                                        id: \.element.id
                                    ) { index, track in
                                        Button {
                                            player.jump(to: index)
                                            dismiss()
                                        } label: {
                                            TrackRowContent(
                                                artworkURL: track.artworkURL,
                                                title: usableMetadata(track.title),
                                                artist: usableMetadata(track.artist),
                                                showsLikedBadge: true,
                                                likedTrack: track,
                                                durationText: nil,
                                                showsPlaybackIndicator: index == player.currentIndex,
                                                isPlaying: player.isPlaying
                                            )
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
                                            L10n.text("play_from_queue")
                                        )
                                        .accessibilityAddTraits(
                                            index == player.currentIndex
                                                ? .isSelected
                                                : []
                                        )
                                        .accessibilityAction(
                                            named: L10n.text("remove_from_queue")
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
                                                    L10n.text("remove_from_queue"),
                                                    systemImage: "trash"
                                                )
                                            }
                                        }
                                        if index < player.queue.count - 1 {
                                            Divider().padding(.leading, 60)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, PremiumLayout.screenPadding)
                        .padding(.vertical, BubbleSpacing.l)
                    }
                }
            }
            .background(ThemeBackground())
            .navigationTitle(L10n.text("player.queue"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("done")) { dismiss() }
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
        return metadata.isEmpty ? L10n.text("track_singular") : metadata
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
            content.accessibilityValue(L10n.text("current_track"))
        } else {
            content
        }
    }
}
