import SwiftUI
import Foundation

struct TrackRow: View {
    @Environment(AppEnvironment.self) private var environment
    /// Rows deliberately do not observe `AudioPlayer`: its buffering /
    /// duration / shuffle updates would invalidate every visible cell.
    /// Identity + play state come from `highlight`, actions go through
    /// `environment.player`.
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(AppSettings.self) private var settings
    @Environment(OfflineTrackStore.self) private var offlineStore
    @Environment(MixFeedbackStore.self) private var mixFeedbackStore
    let track: Track
    let queue: [Track]
    var source: QueueSource? = nil
    var showsOfflineState = true
    var showsLikedBadge = true
    var showsDuration = true
    var showsPlaybackIndicator = true
    @State private var sharingTrack: Track?

    var body: some View {
        Button {
            Haptics.selection()
            environment.player.play(track, in: queue, source: source)
        } label: {
            TrackRowContent(
                artworkURL: track.artworkURL,
                title: usableMetadata(track.title),
                artist: usableMetadata(track.artist),
                titleColor: isCurrent ? currentTrackColor : .primary,
                showsOfflineState: showsOfflineState
                    && OfflineDownloadsFeature.showsControls
                    && !environment.isShareSessionActive,
                isOffline: offlineStore.contains(track),
                isDownloading: offlineStore.downloadingTrackIDs.contains(track.id),
                showsLikedBadge: showsLikedBadge,
                likedTrack: showsLikedBadge ? track : nil,
                durationText: showsDuration ? track.duration.formattedDuration : nil,
                showsPlaybackIndicator: showsPlaybackIndicator && isCurrent,
                isPlaying: highlight.isPlaying,
                playbackIndicatorColor: currentTrackColor
            )
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .modifier(CurrentTrackAccessibilityValueModifier(isCurrent: isCurrent))
        .accessibilityHint(L10n.text("play_track"))
        .trackShareSheet(track: $sharingTrack)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Haptics.selection()
                environment.player.playNext(track)
            } label: {
                Label(L10n.text("play_next"),
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            .tint(settings.theme.accent)
            Button {
                Haptics.selection()
                environment.player.playLast(track)
            } label: {
                Label(L10n.text("play_last"),
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }
            .tint(BubbleGamut.mix.color)
        }
        .contextMenu {
            Button {
                environment.player.playNext(track)
            } label: {
                Label(L10n.text("play_next"),
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            Button {
                environment.player.playLast(track)
            } label: {
                Label(L10n.text("play_last"),
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }
            Button {
                Haptics.open()
                environment.player.play(track, in: queue, source: source)
                environment.player.presentPlayer()
            } label: {
                Label(L10n.text("open_player"), systemImage: "play.circle")
            }
            TrackMixActions.menuButtons(
                for: track,
                environment: environment,
                includeDislike: !mixFeedbackStore.isBanned(track)
            )
            Button {
                Haptics.open()
                sharingTrack = track
            } label: {
                Label(L10n.text("share_audio_file"),
                    systemImage: "square.and.arrow.up"
                )
            }
            if OfflineDownloadsFeature.showsControls,
               !environment.isShareSessionActive {
                Button(
                    role: offlineStore.contains(track) ? .destructive : nil
                ) {
                    toggleOffline()
                } label: {
                    Label(
                        offlineStore.contains(track)
                            ? "remove_download"
                            : "download",
                        systemImage: offlineStore.contains(track)
                            ? "trash"
                            : "arrow.down.circle"
                    )
                }
                .disabled(
                    offlineStore.downloadingTrackIDs.contains(track.id)
                )
            }
        }
    }

    private var isCurrent: Bool {
        highlight.isCurrent(track.id)
    }

    private var currentTrackColor: Color {
        settings.theme == .dark
            ? settings.theme.accent
            : .black
    }

    private var accessibilityLabel: String {
        let metadata = [
            usableMetadata(track.title),
            usableMetadata(track.artist)
        ]
            .compactMap { $0 }
            .joined(separator: " — ")
        guard !metadata.isEmpty else { return spokenDuration }
        return L10n.format("spoken_metadata_0_1", metadata, spokenDuration)
    }

    private var spokenDuration: String {
        guard track.duration.isFinite, track.duration >= 0 else {
            return L10n.seconds(0)
        }
        let total = Int(track.duration)
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 {
            return L10n.seconds(seconds)
        }
        if seconds == 0 {
            return L10n.minutes(minutes)
        }
        return L10n.format(
            "n_0_1_3",
            L10n.minutes(minutes),
            L10n.seconds(seconds)
        )
    }

    private func toggleOffline() {
        Task {
            do {
                if offlineStore.contains(track) {
                    offlineStore.remove(track)
                } else {
                    try await environment.downloadForOffline(track)
                }
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                environment.player.errorMessage = L10n.format(
                    "could_not_save_the_track_offline_0",
                    error.localizedDescription
                )
            }
        }
    }

    private func usableMetadata(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct TrackRowContent: View {
    let artworkURL: URL?
    let title: String?
    let artist: String?
    var titleColor: Color = .primary
    var showsOfflineState = false
    var isOffline = false
    var isDownloading = false
    var showsLikedBadge = true
    var likedTrack: Track?
    var durationText: String?
    var showsPlaybackIndicator = false
    var isPlaying = false
    var playbackIndicatorColor: Color = .primary

    var body: some View {
        HStack(spacing: BubbleSpacing.m) {
            AsyncArtwork(url: artworkURL, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }
                if let artist {
                    Text(artist)
                        .font(BubbleType.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: BubbleSpacing.s) {
                if showsOfflineState {
                    if isOffline {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("available_offline"))
                    } else if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("downloading"))
                    }
                }

                if showsLikedBadge, let likedTrack {
                    LikedTrackBadge(track: likedTrack)
                }

                if let durationText {
                    Text(durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                if showsPlaybackIndicator {
                    PlaybackIndicatorView(
                        isPlaying: isPlaying,
                        color: playbackIndicatorColor
                    )
                    .font(.caption)
                    .foregroundStyle(playbackIndicatorColor)
                    .frame(width: 14, alignment: .center)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .contentShape(Rectangle())
    }
}

private struct CurrentTrackAccessibilityValueModifier: ViewModifier {
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

extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
