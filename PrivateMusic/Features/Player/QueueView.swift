import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    private var isMixQueue: Bool {
        if case .mix = player.queueSource { return true }
        return false
    }

    private var upcomingOffsets: [Int] {
        QueuePresentationPolicy.upcomingOffsets(
            queueCount: player.queue.count,
            currentIndex: player.currentIndex
        )
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
                    queueList
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

    private var queueList: some View {
        List {
            if isMixQueue {
                Section {
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
                    .listRowBackground(Color.clear)
                } header: {
                    Text(L10n.text("mix_radio"))
                } footer: {
                    Text(
                        L10n.text(
                            "diversifies_the_queue_closer_to_track_and_more_novelty_pull_vk_recommend"
                        )
                    )
                }
            }

            if let currentIndex = player.currentIndex,
               player.queue.indices.contains(currentIndex) {
                Section(L10n.text("player.now_playing_kicker")) {
                    queueRow(
                        track: player.queue[currentIndex],
                        index: currentIndex,
                        isCurrent: true
                    )
                }
            }

            if !upcomingOffsets.isEmpty {
                Section(L10n.text("player.up_next")) {
                    ForEach(
                        Array(player.queue.enumerated()).filter {
                            upcomingOffsets.contains($0.offset)
                        },
                        id: \.element.id
                    ) { index, track in
                        queueRow(
                            track: track,
                            index: index,
                            isCurrent: false
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func queueRow(
        track: Track,
        index: Int,
        isCurrent: Bool
    ) -> some View {
        Button {
            player.jump(to: index)
            dismiss()
        } label: {
            TrackRowContent(
                artworkURL: track.artworkURL,
                title: usableMetadata(track.title),
                artist: usableMetadata(track.artist),
                titleColor: isCurrent
                    ? settings.theme.accent
                    : .primary,
                showsLikedBadge: true,
                likedTrack: track,
                durationText: nil,
                showsPlaybackIndicator: isCurrent,
                isPlaying: player.isPlaying,
                playbackIndicatorColor: isCurrent
                    ? settings.theme.accent
                    : .primary
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isCurrent
                ? settings.theme.accent.opacity(0.08)
                : Color.clear
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: track))
        .modifier(
            CurrentQueueItemAccessibilityValueModifier(
                isCurrent: isCurrent
            )
        )
        .accessibilityHint(
            L10n.text(isCurrent ? "current_track" : "play_from_queue")
        )
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(
            named: L10n.text("remove_from_queue")
        ) {
            removeFromQueue(at: index)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isCurrent {
                Button {
                    Haptics.selection()
                    player.playNext(track)
                } label: {
                    Label(
                        L10n.text("play_next"),
                        systemImage: "text.line.first.and.arrowtriangle.forward"
                    )
                }
                .tint(settings.theme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                removeFromQueue(at: index)
            } label: {
                Label(
                    L10n.text("remove_from_queue"),
                    systemImage: "trash"
                )
            }
        }
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
