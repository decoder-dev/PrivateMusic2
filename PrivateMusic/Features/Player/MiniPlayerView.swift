import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(PlaybackProgressModel.self) private var progress
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGSize = .zero
    let playerNamespace: Namespace.ID
    /// Legacy floating dock needs its own glass plate. The iOS 26.1+
    /// `tabViewBottomAccessory` already provides system chrome — stacking
    /// another plate reads as a detached black pill over the tab bar.
    var showsOwnGlassChrome: Bool = true

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: MiniPlayerLayoutMetrics.contentSpacing) {
                    openPlayerArea(track)
                    transportControls
                }
                .padding(.horizontal, MiniPlayerLayoutMetrics.horizontalPadding)
                .padding(.top, MiniPlayerLayoutMetrics.verticalPadding)
                .padding(
                    .bottom,
                    MiniPlayerLayoutMetrics.progressTopSpacing
                )

                progressBar
            }
            .frame(minHeight: MiniPlayerLayoutMetrics.minHeight)
            .modifier(
                MiniPlayerChromeModifier(
                    showsOwnGlassChrome: showsOwnGlassChrome,
                    shape: containerShape,
                    tint: settings.theme.accent.opacity(
                        MiniPlayerLayoutMetrics.glassTintOpacity
                    ),
                    shadowOpacity: settings.theme == .dark ? 0.18 : 0.08
                )
            )
            .miniPlayerTransitionSource(playerNamespace)
            .offset(liveDragOffset)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.32, dampingFraction: 0.86),
                value: dragOffset == .zero
            )
            .transition(appearanceTransition)
            .simultaneousGesture(miniPlayerGesture)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Open zone (artwork + metadata)

    private func openPlayerArea(_ track: Track) -> some View {
        Button {
            Haptics.open()
            player.presentPlayer()
        } label: {
            HStack(spacing: MiniPlayerLayoutMetrics.contentSpacing) {
                artwork(for: track)
                trackMetadata(track)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("n_0_1_2", track.title, track.artist)
        )
        .accessibilityValue(L10n.text(playbackAccessibilityValue))
        .accessibilityHint(L10n.text("open_full_screen_player"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L10n.text("previous_track")) {
            Haptics.trackChange()
            player.previous()
        }
        .accessibilityAction(named: L10n.text("next_track")) {
            Haptics.trackChange()
            player.next()
        }
        .accessibilityAction(named: L10n.text("open_player")) {
            Haptics.open()
            player.presentPlayer()
        }
    }

    private func artwork(for track: Track) -> some View {
        MiniPlayerArtworkView(
            url: track.artworkURL,
            size: MiniPlayerLayoutMetrics.artworkSize,
            cornerRadius: MiniPlayerLayoutMetrics.artworkCornerRadius,
            showsShadow: true
        )
        .id(track.id)
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.92))
        )
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.34, dampingFraction: 0.84),
            value: track.id
        )
    }

    private func trackMetadata(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(track.artist)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: MiniPlayerLayoutMetrics.controlSpacing) {
            previousControl
            playPauseControl
            nextControl
        }
    }

    private var previousControl: some View {
        Button {
            Haptics.trackChange()
            player.previous()
        } label: {
            Image(systemName: "backward.fill")
                .font(.system(size: 19, weight: .semibold))
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                // Actions are circles, per BubbleShapeLanguage.
                .contentShape(BubbleShapeLanguage.action)
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel(L10n.text("previous_track"))
    }

    @ViewBuilder
    private var playPauseControl: some View {
        if player.isBuffering {
            ProgressView()
                .controlSize(.regular)
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                .accessibilityLabel(L10n.text("buffering"))
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
                .font(.system(size: 20, weight: .semibold))
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityLabel(
                L10n.text(
                    player.isPlaying
                        ? "pause"
                        : "resume_playback"
                )
            )
        }
    }

    private var nextControl: some View {
        Button {
            Haptics.trackChange()
            player.next()
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 19, weight: .semibold))
                .frame(
                    width: MiniPlayerLayoutMetrics.tapTarget,
                    height: MiniPlayerLayoutMetrics.tapTarget
                )
                // Actions are circles, per BubbleShapeLanguage.
                .contentShape(BubbleShapeLanguage.action)
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel(L10n.text("next_track"))
    }

    // MARK: - Progress

    private var progressBar: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * progressFraction)
                }
        }
        .frame(height: MiniPlayerLayoutMetrics.progressHeight)
        .padding(.horizontal, MiniPlayerLayoutMetrics.progressSideInset)
        .padding(.bottom, MiniPlayerLayoutMetrics.progressBottomInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Gestures / chrome

    private var miniPlayerGesture: some Gesture {
        DragGesture(
            minimumDistance: MiniPlayerGesturePolicy.minimumDistance
        )
        .updating($dragOffset) { value, state, _ in
            state = value.translation
        }
        .onEnded { value in
            guard let action = MiniPlayerGesturePolicy.action(
                translation: value.translation,
                predictedEndTranslation: value.predictedEndTranslation
            ) else {
                return
            }
            switch action {
            case .openPlayer:
                Haptics.open()
                player.presentPlayer()
            case .next:
                Haptics.trackChange()
                player.next()
            case .previous:
                Haptics.trackChange()
                player.previous()
            }
        }
    }

    private var liveDragOffset: CGSize {
        MiniPlayerGesturePolicy.dragOffset(
            translation: dragOffset,
            reduceMotion: reduceMotion
        )
    }

    private var appearanceTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .bottom))
        )
    }

    private var containerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: MiniPlayerLayoutMetrics.cornerRadius,
            style: .continuous
        )
    }

    private var progressFraction: CGFloat {
        CGFloat(
            MiniPlayerProgressPolicy.progress(
                elapsedTime: progress.elapsedTime,
                duration: player.duration
            )
        )
    }

    private var playbackAccessibilityValue: String {
        if player.isBuffering {
            return "buffering"
        }
        if player.isPlaying {
            return "playing"
        }
        return "paused"
    }
}

/// Optional own glass plate for the mini player. System tab accessories
/// already provide Liquid Glass; stacking another plate looks broken.
private struct MiniPlayerChromeModifier<S: Shape>: ViewModifier {
    let showsOwnGlassChrome: Bool
    let shape: S
    let tint: Color
    let shadowOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsOwnGlassChrome {
            content
                .adaptiveGlass(
                    in: shape,
                    interactive: true,
                    tint: tint
                )
                .shadow(
                    color: .black.opacity(shadowOpacity),
                    radius: MiniPlayerLayoutMetrics.containerShadowRadius,
                    y: MiniPlayerLayoutMetrics.containerShadowY
                )
        } else {
            content
        }
    }
}

extension View {
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
