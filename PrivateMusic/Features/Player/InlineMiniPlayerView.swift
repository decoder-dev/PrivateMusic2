import SwiftUI

/// Compact mini player for the system tab-bar accessory when it collapses
/// to the inline placement. Relies on system chrome — no own glass plate.
struct InlineMiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playerNamespace: Namespace.ID

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: MiniPlayerLayoutMetrics.inlineContentSpacing) {
                openPlayerArea(track)
                playPauseControl
            }
            .padding(.horizontal, MiniPlayerLayoutMetrics.inlineHorizontalPadding)
            .padding(.vertical, MiniPlayerLayoutMetrics.inlineVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: MiniPlayerLayoutMetrics.tapTarget)
            .contentShape(Rectangle())
            .miniPlayerTransitionSource(playerNamespace)
            .accessibilityElement(children: .contain)
        }
    }

    private func openPlayerArea(_ track: Track) -> some View {
        Button {
            Haptics.open()
            player.presentPlayer()
        } label: {
            HStack(spacing: MiniPlayerLayoutMetrics.inlineContentSpacing) {
                MiniPlayerArtworkView(
                    url: track.artworkURL,
                    size: MiniPlayerLayoutMetrics.inlineArtworkSize,
                    cornerRadius: MiniPlayerLayoutMetrics.inlineArtworkCornerRadius,
                    showsShadow: false
                )
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.title)
        .accessibilityValue(L10n.text(playbackAccessibilityValue))
        .accessibilityHint(L10n.text("Открыть полноэкранный плеер"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L10n.text("Открыть плеер")) {
            Haptics.open()
            player.presentPlayer()
        }
        .accessibilityAction(named: L10n.text("Предыдущий трек")) {
            Haptics.trackChange()
            player.previous()
        }
        .accessibilityAction(named: L10n.text("Следующий трек")) {
            Haptics.trackChange()
            player.next()
        }
    }

    @ViewBuilder
    private var playPauseControl: some View {
        if MiniPlayerAccessoryPolicy.showsBufferingIndicator(
            isBuffering: player.isBuffering
        ) {
            ProgressView()
                .controlSize(.small)
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                .accessibilityLabel(L10n.text("Буферизация"))
        } else {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                Image(
                    systemName: player.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.system(size: 15, weight: .semibold))
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.text(
                    player.isPlaying
                        ? "Приостановить"
                        : "Продолжить воспроизведение"
                )
            )
        }
    }

    private var playbackAccessibilityValue: String {
        if player.isBuffering {
            return "Буферизация"
        }
        if player.isPlaying {
            return "Воспроизводится"
        }
        return "На паузе"
    }
}
