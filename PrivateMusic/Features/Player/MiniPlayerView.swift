import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGSize = .zero
    let playerNamespace: Namespace.ID

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        Haptics.open()
                        player.presentPlayer()
                    } label: {
                        HStack(spacing: 10) {
                            AsyncArtwork(url: track.artworkURL, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        L10n.format(
                            "%@ — %@",
                            track.title,
                            track.artist
                        )
                    )
                    .accessibilityHint(
                        L10n.text("Открыть полноэкранный плеер")
                    )

                    HStack(spacing: 0) {
                        Button {
                            Haptics.trackChange()
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .accessibilityLabel(L10n.text("Предыдущий трек"))

                        miniPlayPauseButton

                        Button {
                            Haptics.trackChange()
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .accessibilityLabel(L10n.text("Следующий трек"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tint)
                                .frame(
                                    width: proxy.size.width * progress
                                )
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)
            }
            .adaptiveGlass(
                in: containerShape,
                interactive: true,
                tint: settings.theme.accent.opacity(0.04)
            )
            .shadow(
                color: .black.opacity(settings.theme == .dark ? 0.24 : 0.12),
                radius: 12,
                y: 6
            )
            .miniPlayerTransitionSource(playerNamespace)
            .frame(minHeight: 58)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(
                        with: .move(edge: .trailing)
                    ),
                    removal: .opacity.combined(
                        with: .move(edge: .leading)
                    )
                )
            )
            .offset(
                x: reduceMotion ? 0 : dragOffset.width * 0.12,
                y: reduceMotion ? 0 : min(dragOffset.height * 0.08, 0)
            )
            .simultaneousGesture(miniPlayerGesture)
        }
    }

    @ViewBuilder
    private var miniPlayPauseButton: some View {
        let label = L10n.text(
            player.isPlaying
                ? "Приостановить"
                : "Продолжить воспроизведение"
        )
        if #available(iOS 26.0, *) {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                Image(
                    systemName: player.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.headline)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .clipShape(Circle())
            .tint(settings.theme.accent)
            .accessibilityLabel(label)
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
                .font(.headline)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityLabel(label)
        }
    }

    private var miniPlayerGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(vertical) > abs(horizontal), vertical < -42 {
                    Haptics.open()
                    player.presentPlayer()
                } else if horizontal < -58 {
                    Haptics.trackChange()
                    player.next()
                } else if horizontal > 58 {
                    Haptics.trackChange()
                    player.previous()
                }
            }
    }

    private var containerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.compactRadius,
            style: .continuous
        )
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(
            min(max(player.elapsedTime / player.duration, 0), 1)
        )
    }
}

private extension View {
    /// Marks the mini player as the visual origin for the zoom transition
    /// into PlayerView (see RootView.playerZoomTransition). No-op below
    /// iOS 18, where the full-screen cover just slides up as before.
    @ViewBuilder
    func miniPlayerTransitionSource(
        _ namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(
                id: PlayerZoomTransition.sourceID,
                in: namespace
            )
        } else {
            self
        }
    }
}
