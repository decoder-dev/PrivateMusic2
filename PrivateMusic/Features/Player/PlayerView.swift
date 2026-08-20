import SwiftUI
import UIKit
import AVKit

struct PlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(OfflineTrackStore.self) private var offlineStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @GestureState private var artworkDrag: CGSize = .zero
    @State private var presentedSheet: PlayerSheet?
    @State private var deferredPlayerAction: DeferredPlayerAction?
    @State private var isInLibrary = false
    @State private var isUpdatingLibrary = false
    @State private var showCopiedToast = false
    @State private var showRouteHint = false
    @State private var routeHintToken = UUID()
    @State private var sharingTrack: Track?
    /// Set from the layout so a vertical scroll on the accessibility
    /// player is not also read as a full-screen dismiss.
    @State private var usesScrollingLayout = false

    /// The tester feedback that started this: on iOS 26 the player picks up
    /// Liquid Glass, and people coming from iOS 18 read the translucent
    /// pills as visual noise. Every glass branch here already carries a
    /// complete pre-26 fallback, so the switch just routes to it.
    /// Increase Contrast and Reduce Transparency flatten custom glass
    /// the same way `adaptiveGlass` does — a lone glass pill on an
    /// otherwise opaque player reads as a rendering bug.
    private var usesGlassChrome: Bool {
        !ContrastPolicy.flattensCustomGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            prefersClassicChrome: settings.classicChrome
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                artworkBackground

                if let track = player.currentTrack {
                    playerContent(
                        track,
                        size: proxy.size,
                        safeInsets: proxy.safeAreaInsets
                    )
                } else {
                    EmptyStateView(
                        title: "player",
                        systemImage: "play.circle",
                        description: "choose_a_track_from_your_library_or_a_mix"
                    )
                    .foregroundStyle(playerForeground)
                    .padding()
                    .onAppear { usesScrollingLayout = false }
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(fullScreenDismissGesture)
        .background(playerBackground.ignoresSafeArea())
        // RootView already sets this for the whole app; repeated here
        // because the player arrives through a `fullScreenCover` and its
        // own sheets (queue, actions) hang off this view, not off Root.
        .environment(\.prefersClassicChrome, !usesGlassChrome)
        .preferredColorScheme(settings.theme.colorScheme)
        .sheet(
            item: $presentedSheet,
            onDismiss: handleSheetDismissal
        ) { sheet in
            presentedSheetContent(sheet)
        }
        .trackShareSheet(track: $sharingTrack)
        .onAppear {
            honorPendingPlayerSheet()
        }
        .onChange(of: player.pendingPlayerSheet) { sheet in
            guard sheet != nil else { return }
            honorPendingPlayerSheet()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            deferredPlayerAction = nil
            updateLibraryState()
            isUpdatingLibrary = false
            if isActionSheetPresented {
                presentedSheet = nil
            }
        }
        .task(id: player.currentTrack?.id) {
            updateLibraryState()
        }
        .onChange(of: libraryStore.signatures) { _ in
            updateLibraryState()
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if showRouteHint {
                    AudioProcessingRouteHintBanner()
                }
                if showCopiedToast {
                    Text(L10n.text("link_copied"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .adaptiveGlass(in: Capsule())
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 40)
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
        .animation(.easeInOut(duration: 0.3), value: showRouteHint)
    }

    private var artworkBackground: some View {
        ZStack {
            playerBackground
            if let artworkURL = player.currentTrack?.artworkURL {
                CachedRemoteImage(
                    url: artworkURL,
                    maxPixelSize: PlayerArtworkBackgroundPolicy.maxPixelSize
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.28)
                        .blur(radius: PlayerArtworkBackgroundPolicy.blurRadius)
                        .saturation(1.12)
                        .opacity(settings.theme == .light ? 0.18 : 1)
                } placeholder: {
                    Color.clear
                }
                .id(player.currentTrack?.id)
            }
            playerBackground.opacity(settings.theme == .light ? 0.72 : 0.56)
            LinearGradient(
                colors: backgroundGradient,
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .drawingGroup(opaque: true)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func playerContent(
        _ track: Track,
        size: CGSize,
        safeInsets: EdgeInsets
    ) -> some View {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: size,
            safeBottom: safeInsets.bottom,
            safeLeading: safeInsets.leading,
            safeTrailing: safeInsets.trailing,
            usesAccessibilityText: dynamicTypeSize.isAccessibilitySize,
            accessibilityStep: PlayerAccessibilityPolicy.step(
                for: dynamicTypeSize
            ),
            hasAlbum: track.albumTitle?.isEmpty == false
        )
        let scrolling = metrics.requiresAccessibilityScrolling(
            containerHeight: size.height
        )

        Group {
            if metrics.requiresAccessibilityScrolling(
                containerHeight: size.height
            ) {
                // Spacers inside a ScrollView grow without a ceiling and
                // the player becomes infinitely tall. Stack with fixed
                // gaps so the scroll view's content size is the layout.
                ScrollView(.vertical) {
                    if metrics.mode == .landscape {
                        landscapePlayerContent(
                            track,
                            metrics: metrics,
                            flexible: false
                        )
                    } else {
                        portraitPlayerContent(
                            track,
                            metrics: metrics,
                            flexible: false
                        )
                    }
                }
                .scrollIndicators(.hidden)
            } else if metrics.mode == .landscape {
                landscapePlayerContent(
                    track,
                    metrics: metrics,
                    flexible: true
                )
            } else {
                portraitPlayerContent(
                    track,
                    metrics: metrics,
                    flexible: true
                )
            }
        }
        .frame(
            width: metrics.contentWidth,
            height: size.height
        )
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .foregroundStyle(playerForeground)
        .onAppear { usesScrollingLayout = scrolling }
        .onChange(of: scrolling) { _, value in
            usesScrollingLayout = value
        }
    }

    private func portraitPlayerContent(
        _ track: Track,
        metrics: PlayerLayoutMetrics,
        flexible: Bool
    ) -> some View {
        VStack(spacing: 0) {
            playerHeader(track)
                .frame(height: metrics.headerHeight)
                .padding(.top, metrics.headerTopPadding)

            playerStackGap(metrics.artworkTopSpacing, flexible: flexible)

            playerArtwork(track, size: metrics.artworkSize)

            playerStackGap(metrics.metadataTopSpacing, flexible: flexible)

            trackMetadata(track)

            playerStackGap(metrics.progressTopSpacing, flexible: flexible)

            progressControls

            playerStackGap(metrics.controlsTopSpacing, flexible: flexible)

            primaryControls
                .frame(height: metrics.primaryControlsHeight)

            playerStackGap(metrics.quickActionsTopSpacing, flexible: flexible)

            quickActions(track)
                .frame(minHeight: metrics.quickActionsHeight)

            Color.clear
                .frame(height: metrics.bottomPadding)
                .accessibilityHidden(true)
        }
    }

    private func landscapePlayerContent(
        _ track: Track,
        metrics: PlayerLayoutMetrics,
        flexible: Bool
    ) -> some View {
        VStack(spacing: 0) {
            playerHeader(track)
                .frame(height: metrics.headerHeight)
                .padding(.top, metrics.headerTopPadding)

            playerStackGap(metrics.artworkTopSpacing, flexible: flexible)

            HStack(spacing: metrics.landscapeColumnSpacing) {
                playerArtwork(track, size: metrics.artworkSize)

                VStack(spacing: 0) {
                    trackMetadata(track)

                    playerStackGap(
                        metrics.progressTopSpacing,
                        flexible: flexible
                    )

                    progressControls

                    playerStackGap(
                        metrics.controlsTopSpacing,
                        flexible: flexible
                    )

                    primaryControls
                        .frame(height: metrics.primaryControlsHeight)
                }
                .frame(maxHeight: flexible ? .infinity : nil)
            }
            .frame(maxHeight: flexible ? .infinity : nil)

            playerStackGap(metrics.quickActionsTopSpacing, flexible: flexible)

            quickActions(track)
                .frame(minHeight: metrics.quickActionsHeight)

            Color.clear
                .frame(height: metrics.bottomPadding)
                .accessibilityHidden(true)
        }
    }

    /// `Spacer` is for the fitted player. Inside a ScrollView it expands
    /// without bound, so the accessibility layout uses a fixed gap.
    @ViewBuilder
    private func playerStackGap(
        _ length: CGFloat,
        flexible: Bool
    ) -> some View {
        if flexible {
            Spacer(minLength: length)
        } else {
            Color.clear
                .frame(height: length)
                .accessibilityHidden(true)
        }
    }

    private func playerHeader(_ track: Track) -> some View {
        // Plain ZStack — not AdaptiveGlassContainer. Sibling interactive
        // glass circles inside GlassEffectContainer morph into one blob
        // on iOS 26 (same failure mode primaryControls documents).
        ZStack {
            VStack(spacing: 2) {
                Text(L10n.text("player.now_playing_kicker"))
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(playerSecondary)
                Text(player.queueContextTitle.uppercased())
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                    .foregroundStyle(playerSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, PlayerHeaderMetrics.titleHorizontalInset)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilitySortPriority(1)

            HStack {
                Color.clear
                    .frame(width: PlayerHeaderMetrics.sideClusterWidth)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    AirPlayRoutePicker(
                        tintColor: UIColor(playerForeground),
                        onWillPresent: handleAirPlayRoutePickerOpened
                    )
                        .frame(width: 44, height: 44)
                        .adaptiveGlass(
                            in: Circle(),
                            interactive: true
                        )
                        .accessibilityLabel(
                            L10n.text(
                                "choose_playback_device"
                            )
                        )
                        .accessibilitySortPriority(3)
                    actionMenuButton(track)
                        .accessibilitySortPriority(2)
                }
                .frame(width: PlayerHeaderMetrics.sideClusterWidth)
            }
        }
    }

    private func playerArtwork(
        _ track: Track,
        size: CGFloat
    ) -> some View {
        let layout = PlayerArtworkCarouselPolicy.layout(for: size)
        let neighbors = PlayerArtworkCarouselPolicy.neighborIndices(
            queueCount: player.queue.count,
            currentIndex: player.currentIndex,
            repeatMode: player.repeatMode
        )

        return ZStack {
            ZStack {
                if let previousIndex = neighbors.previous,
                   player.queue.indices.contains(previousIndex) {
                    carouselNeighbor(
                        player.queue[previousIndex],
                        size: layout.neighborSize,
                        role: "previous"
                    )
                    .offset(x: -layout.neighborOffset)
                }
                if let nextIndex = neighbors.next,
                   player.queue.indices.contains(nextIndex) {
                    carouselNeighbor(
                        player.queue[nextIndex],
                        size: layout.neighborSize,
                        role: "next"
                    )
                    .offset(x: layout.neighborOffset)
                }
            }
            .frame(width: size, height: size)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PremiumLayout.artworkRadius(for: size),
                    style: .continuous
                )
            )

            AsyncArtwork(url: track.artworkURL, size: layout.centerSize)
                .id(track.id)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.artworkRadius(
                            for: layout.centerSize
                        ),
                        style: .continuous
                    )
                    .stroke(playerForeground.opacity(0.08), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
                .offset(
                    x: reduceMotion ? 0 : artworkDrag.width * 0.16,
                    y: reduceMotion ? 0 : artworkDrag.height * 0.08
                )
                .rotationEffect(
                    .degrees(reduceMotion ? 0 : artworkDrag.width / 65)
                )
        }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .offset(
                x: reduceMotion ? 0 : artworkDrag.width * 0.03
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.3, dampingFraction: 0.82),
                value: artworkDrag == .zero
            )
            .gesture(artworkGesture)
            .accessibilityLabel(
                L10n.format(
                    "artwork_0_1",
                    track.title,
                    track.artist
                )
            )
            .accessibilityHint(
                L10n.text("swipe_sideways_to_change_tracks_up_to_open_the_queue_or_down_to_close_th")
            )
            .accessibilityAction(
                named: L10n.text("next_track")
            ) {
                Haptics.trackChange()
                player.next()
            }
            .accessibilityAction(
                named: L10n.text("previous_track")
            ) {
                Haptics.trackChange()
                player.previous()
            }
            .accessibilityAction(
                named: L10n.text("player.queue")
            ) {
                present(.queue)
            }
            .accessibilityAction(
                named: L10n.text("close_player")
            ) {
                closePlayer()
            }
    }

    private func carouselNeighbor(
        _ track: Track,
        size: CGFloat,
        role: String
    ) -> some View {
        AsyncArtwork(url: track.artworkURL, size: size)
            .id("\(role)-\(track.id)")
            .saturation(0.82)
            .opacity(0.58)
            .overlay {
                RoundedRectangle(
                    cornerRadius: PremiumLayout.artworkRadius(for: size),
                    style: .continuous
                )
                .stroke(playerForeground.opacity(0.06), lineWidth: 0.6)
            }
            .accessibilityHidden(true)
    }

    private func trackMetadata(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(playerForeground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                    .minimumScaleFactor(
                        dynamicTypeSize.isAccessibilitySize ? 1 : 0.88
                    )
                Button {
                    present(.artist(track.artist))
                } label: {
                    HStack(spacing: 4) {
                        Text(track.artist)
                            .font(.subheadline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(playerSecondary)
                .disabled(
                    track.artist.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
                .accessibilityHint(L10n.text("player.open_artist"))
                if let album = track.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption2)
                        .foregroundStyle(playerSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }

            Spacer(minLength: 10)

            playerGlassIconButton(
                systemImage: isInLibrary ? "heart.fill" : "heart",
                font: .system(size: 19, weight: .semibold),
                tint: isInLibrary
                    ? playerForeground
                    : playerForeground.opacity(0.72),
                accessibilityLabel: isInLibrary
                    ? "remove_from_library"
                    : "add_to_library_2",
                accessibilityValue: isInLibrary
                    ? "track_is_in_your_library"
                    : "track_is_not_in_your_library",
                disabled: isUpdatingLibrary
            ) {
                toggleLibrary(track)
            }
        }
    }

    private var progressControls: some View {
        PlayerProgressControls(
            duration: player.duration,
            foreground: playerForeground,
            secondary: playerSecondary,
            onSeek: { player.seek(to: $0) }
        )
        .id(player.currentTrack?.id)
    }

    private func actionMenuButton(_ track: Track) -> some View {
        playerGlassIconButton(
            systemImage: "ellipsis",
            font: .headline,
            accessibilityLabel: "track_actions"
        ) {
            present(.actions(track))
        }
    }

    private var primaryControls: some View {
        // Do NOT wrap transport buttons in GlassEffectContainer: iOS 26
        // morphs sibling .glass controls into one merged blob with a
        // liquid neck animation that reads broken and costs frames.
        HStack(spacing: 0) {
            secondaryButton(
                "shuffle",
                active: player.shuffleEnabled,
                label: "shuffle",
                accessibilityValue: player.shuffleEnabled
                    ? "shuffle_on"
                    : "shuffle_off"
            ) {
                Haptics.selection()
                player.toggleShuffle()
            }
            Spacer()
            transportSkipButton(
                systemImage: "backward.fill",
                accessibilityLabel: "previous_track"
            ) {
                Haptics.trackChange()
                player.previous()
            }
            Spacer()
            playPauseButton
            Spacer()
            transportSkipButton(
                systemImage: "forward.fill",
                accessibilityLabel: "next_track"
            ) {
                Haptics.trackChange()
                player.next()
            }
            Spacer()
            secondaryButton(
                player.repeatMode.systemImage,
                active: player.repeatMode != .off,
                label: "repeat",
                accessibilityValue: repeatAccessibilityValue
            ) {
                Haptics.selection()
                player.cycleRepeatMode()
            }
        }
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if #available(iOS 26.0, *), usesGlassChrome {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                playPauseLabel
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .clipShape(Circle())
            .tint(playerForeground)
            .foregroundStyle(playerBackground)
            .controlSize(.large)
            .accessibilityLabel(playPauseAccessibilityLabel)
        } else {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                playPauseLabel
                    .background(playerForeground, in: Circle())
                    .foregroundStyle(playerBackground)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(playPauseAccessibilityLabel)
        }
    }

    private var playPauseLabel: some View {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 29, weight: .bold))
            .frame(width: 64, height: 64)
            .contentShape(Circle())
    }

    private var playPauseAccessibilityLabel: String {
        L10n.text(
            player.isPlaying
                ? "pause"
                : "resume_playback"
        )
    }

    private func quickActions(_ track: Track) -> some View {
        HStack(spacing: 0) {
            ForEach(PlayerQuickAction.allCases) { item in
                quickAction(item) {
                    switch item {
                    case .lyrics: present(.lyrics(track))
                    case .queue: present(.queue)
                    case .playlist: present(.playlists(track))
                    case .share: startShare(track)
                    }
                }
            }
        }
    }

    private func quickAction(
        _ item: PlayerQuickAction,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                quickActionGlyph(item.systemImage)
                Text(L10n.text(item.title))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 2)
            }
            .foregroundStyle(playerForeground.opacity(0.72))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 61)
        }
        .buttonStyle(PlayerControlStyle())
        .accessibilityLabel(L10n.text(item.accessibilityLabel))
    }

    @ViewBuilder
    private func quickActionGlyph(_ image: String) -> some View {
        if #available(iOS 26.0, *), usesGlassChrome {
            Image(systemName: image)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Image(systemName: image)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .adaptiveGlass(in: Circle(), interactive: true)
        }
    }

    @ViewBuilder
    private func transportSkipButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26.0, *), usesGlassChrome {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(playerForeground)
            .accessibilityLabel(L10n.text(accessibilityLabel))
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(L10n.text(accessibilityLabel))
        }
    }

    @ViewBuilder
    private func playerGlassIconButton(
        systemImage: String,
        font: Font = .headline,
        tint: Color? = nil,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        accessibilitySortPriority: Double? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedTint = tint ?? playerForeground
        let button = Group {
            if #available(iOS 26.0, *), usesGlassChrome {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(font)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(resolvedTint)
                .disabled(disabled)
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .font(font)
                        .foregroundStyle(resolvedTint)
                        .frame(width: 44, height: 44)
                        .adaptiveGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(PlayerControlStyle())
                .disabled(disabled)
            }
        }
        .accessibilityLabel(L10n.text(accessibilityLabel))

        if let accessibilityValue {
            button
                .accessibilityValue(L10n.text(accessibilityValue))
                .accessibilitySortPriority(accessibilitySortPriority ?? 0)
        } else if let accessibilitySortPriority {
            button.accessibilitySortPriority(accessibilitySortPriority)
        } else {
            button
        }
    }

    @ViewBuilder
    private func secondaryButton(
        _ image: String,
        active: Bool,
        label: String,
        accessibilityValue: String,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26.0, *), usesGlassChrome {
            Button(action: action) {
                Image(systemName: image)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(
                active
                    ? playerForeground
                    : playerForeground.opacity(0.55)
            )
            .opacity(active ? 1 : 0.85)
            .accessibilityLabel(L10n.text(label))
            .accessibilityValue(L10n.text(accessibilityValue))
        } else {
            Button(action: action) {
                Image(systemName: image)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(
                        active
                            ? playerForeground
                            : playerForeground.opacity(0.58)
                    )
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text(label))
            .accessibilityValue(L10n.text(accessibilityValue))
        }
    }

    private var repeatAccessibilityValue: String {
        switch player.repeatMode {
        case .off:
            return "repeat_off"
        case .all:
            return "repeat_queue"
        case .one:
            return "repeat_one"
        }
    }

    private var playerForeground: Color {
        settings.theme == .light ? .black : .white
    }

    private var playerSecondary: Color {
        playerForeground.opacity(settings.theme == .light ? 0.62 : 0.56)
    }

    private var playerBackground: Color {
        settings.theme == .light ? .white : .black
    }

    private var backgroundGradient: [Color] {
        if settings.theme == .light {
            return [
                .white.opacity(0.28),
                .white.opacity(0.72),
                .white.opacity(0.98),
            ]
        }
        return [
            .black.opacity(0.18),
            .black.opacity(0.42),
            .black.opacity(0.92),
        ]
    }

    @ViewBuilder
    private func presentedSheetContent(_ sheet: PlayerSheet) -> some View {
        @Bindable var settings = settings
        switch sheet {
        case .queue:
            QueueView()
        case let .lyrics(track):
            LyricsView(track: track)
        case let .artist(artist):
            ArtistView(artist: artist)
        case let .playlists(track):
            AddToPlaylistView(track: track)
        case .settings:
            NavigationStack { EqualizerSettingsView() }
        case let .actions(track):
            PlayerActionsSheet(
                track: track,
                isInLibrary: isInLibrary,
                offlineState: offlineStore.state(for: track),
                availability: PlayerActionAvailability(
                    hasSession: sessionStore.accessToken != nil,
                    isUpdatingLibrary: isUpdatingLibrary,
                    showsOfflineControls: OfflineDownloadsFeature.showsControls
                        && !environment.isShareSessionActive
                ),
                equalizerEnabled: $settings.equalizerEnabled,
                spatialAudioEnabled: $settings.spatialAudioEnabled,
                preferHighQuality: $settings.preferHighQuality,
                onDismiss: {
                    presentedSheet = nil
                },
                onLibrary: {
                    presentedSheet = nil
                    toggleLibrary(track)
                },
                onArtist: {
                    deferFromActionSheet(
                        .sheet(.artist(track.artist))
                    )
                },
                onPlaylist: {
                    deferFromActionSheet(
                        .sheet(.playlists(track))
                    )
                },
                onShare: {
                    deferFromActionSheet(.share(track))
                },
                onCopyLink: {
                    presentedSheet = nil
                    copyTrackLink(track)
                },
                onOffline: {
                    presentedSheet = nil
                    toggleOffline(track)
                },
                onSettings: {
                    deferFromActionSheet(.sheet(.settings))
                },
                onProcessingRouteHint: showProcessingRouteHint,
                onDislikeTrack: {
                    presentedSheet = nil
                    environment.dislike(track, includeArtist: false)
                },
                onDislikeArtist: {
                    presentedSheet = nil
                    environment.dislike(track, includeArtist: true)
                },
                onMixFromTrack: {
                    presentedSheet = nil
                    Task { await environment.startMixFromTrack(track) }
                },
                onSnippet: {
                    presentedSheet = nil
                    Task { await environment.previewSnippet(track) }
                },
                showsMixFeedback: true,
                qualityCaption: settings.preferHighQuality
                    ? L10n.text("quality_high_hq_no_hls_cap")
                    : L10n.text("quality_data_saver_160_kbps")
            )
        }
    }

    @discardableResult
    private func present(_ sheet: PlayerSheet) -> Bool {
        guard presentedSheet == nil else { return false }
        presentedSheet = sheet
        return true
    }

    private func honorPendingPlayerSheet() {
        guard let pending = player.consumePendingPlayerSheet() else {
            return
        }
        // Yield so a just-presented fullScreenCover can finish mounting
        // before we open the queue sheet on top.
        Task { @MainActor in
            await Task.yield()
            switch pending {
            case .queue:
                _ = present(.queue)
            }
        }
    }

    private func deferFromActionSheet(_ action: DeferredPlayerAction) {
        deferredPlayerAction = action
        presentedSheet = nil
    }

    private func handleSheetDismissal() {
        guard let action = deferredPlayerAction else { return }
        deferredPlayerAction = nil

        Task { @MainActor in
            await Task.yield()
            switch action {
            case let .sheet(sheet):
                _ = present(sheet)
            case let .share(track):
                startShare(track)
            }
        }
    }

    private var isActionSheetPresented: Bool {
        guard let presentedSheet else { return false }
        if case .actions = presentedSheet {
            return true
        }
        return false
    }

    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($artworkDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(horizontal) > abs(vertical) {
                    if horizontal < -58 {
                        Haptics.trackChange()
                        player.next()
                    } else if horizontal > 58 {
                        Haptics.trackChange()
                        player.previous()
                    }
                } else if vertical < -60 {
                    present(.queue)
                } else if PlayerDismissGesturePolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) {
                    closePlayer()
                }
            }
    }

    private var fullScreenDismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard !usesScrollingLayout,
                      presentedSheet == nil,
                      sharingTrack == nil,
                      PlayerDismissGesturePolicy.shouldDismiss(
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation
                      ) else {
                    return
                }
                closePlayer()
            }
    }

    private func closePlayer() {
        presentedSheet = nil
        deferredPlayerAction = nil
        player.dismissPlayer()
    }

    private func startShare(_ track: Track) {
        Haptics.open()
        // Never present the share preparation sheet on top of another
        // player sheet — nested modal presentations crash on device.
        if presentedSheet != nil {
            deferFromActionSheet(.share(track))
            return
        }
        sharingTrack = track
    }

    private func copyTrackLink(_ track: Track) {
        let url = "https://vk.com/audio\(track.ownerID)_\(track.trackID)"
        UIPasteboard.general.string = url
        Haptics.selection()
        showCopiedToast = true

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            showCopiedToast = false
        }
    }

    private func handleAirPlayRoutePickerOpened() {
        guard settings.equalizerEnabled || settings.spatialAudioEnabled else {
            return
        }
        showProcessingRouteHint()
    }

    private func showProcessingRouteHint() {
        let token = UUID()
        routeHintToken = token
        Haptics.open()
        showRouteHint = true
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard routeHintToken == token else { return }
            showRouteHint = false
        }
    }

    private func toggleLibrary(_ track: Track) {
        guard !isUpdatingLibrary,
              sessionStore.accessToken != nil else {
            return
        }
        let removing = isInLibrary
        isUpdatingLibrary = true
        Task {
            defer { isUpdatingLibrary = false }
            do {
                if removing {
                    let stored = libraryStore.storedTrack(for: track) ?? track
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.removeFromLibrary(
                            stored,
                            accessToken: token
                        )
                    }
                    libraryStore.markRemoved(track)
                    libraryStore.markRemoved(stored)
                    MusicLibraryEvents.postRemoved(stored)
                    if player.currentTrack?.id == track.id {
                        isInLibrary = false
                    }
                } else {
                    let added = try await environment.withAuthorizedToken {
                        token in
                        try await environment.musicService.addToLibrary(
                            track,
                            accessToken: token
                        )
                    }
                    libraryStore.markAdded(source: track, stored: added)
                    MusicLibraryEvents.postAdded(added)
                    if player.currentTrack?.id == track.id {
                        isInLibrary = true
                    }
                }
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                player.errorMessage = L10n.format(
                    removing
                        ? "could_not_remove_the_track_0"
                        : "could_not_add_the_track_0",
                    error.localizedDescription
                )
            }
        }
    }

    private func updateLibraryState() {
        guard let track = player.currentTrack else {
            isInLibrary = false
            return
        }
        isInLibrary = libraryStore.contains(track)
            || track.ownerID == sessionStore.session?.userID
    }

    private func toggleOffline(_ track: Track) {
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
                player.errorMessage = L10n.format(
                    "could_not_save_the_track_offline_0",
                    error.localizedDescription
                )
            }
        }
    }
}

enum PlayerLayoutMode: Equatable {
    case compact
    case standard
    case tall
    case landscape
}

struct PlayerLayoutMetrics: Equatable {
    let mode: PlayerLayoutMode
    let usesAccessibilityText: Bool
    let contentWidth: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let headerHeight: CGFloat
    let headerTopPadding: CGFloat
    let artworkSize: CGFloat
    let artworkTopSpacing: CGFloat
    let metadataTopSpacing: CGFloat
    let progressTopSpacing: CGFloat
    let controlsTopSpacing: CGFloat
    let primaryControlsHeight: CGFloat
    let quickActionsTopSpacing: CGFloat
    let quickActionsHeight: CGFloat
    let bottomPadding: CGFloat
    let landscapeColumnSpacing: CGFloat
    let minimumContentHeight: CGFloat

    static func resolve(
        containerSize: CGSize,
        safeBottom: CGFloat = 0,
        safeLeading: CGFloat = 0,
        safeTrailing: CGFloat = 0,
        usesAccessibilityText: Bool = false,
        accessibilityStep: Int = 1,
        hasAlbum: Bool = true
    ) -> PlayerLayoutMetrics {
        let isLandscape =
            containerSize.width > containerSize.height * 1.12
        let mode: PlayerLayoutMode
        if isLandscape {
            mode = .landscape
        } else if containerSize.height < 720 {
            mode = .compact
        } else if containerSize.height < 860 {
            mode = .standard
        } else {
            mode = .tall
        }

        let portraitProgress = min(
            max((containerSize.height - 667) / (932 - 667), 0),
            1
        )
        func portraitValue(
            _ compact: CGFloat,
            _ tall: CGFloat
        ) -> CGFloat {
            compact + (tall - compact) * portraitProgress
        }
        let baseHorizontalPadding: CGFloat = mode == .landscape
            ? 14
            : portraitValue(18, 22)
        let leadingPadding = max(
            baseHorizontalPadding,
            safeLeading + (mode == .landscape ? 8 : 0)
        )
        let trailingPadding = max(
            baseHorizontalPadding,
            safeTrailing + (mode == .landscape ? 8 : 0)
        )
        let contentWidth = max(
            containerSize.width - leadingPadding - trailingPadding,
            0
        )

        let headerHeight: CGFloat = 44
        let headerTopPadding: CGFloat
        let artworkTopSpacing: CGFloat
        let metadataTopSpacing: CGFloat
        let progressTopSpacing: CGFloat
        let controlsTopSpacing: CGFloat
        let quickActionsTopSpacing: CGFloat
        let artworkRatio: CGFloat

        if mode == .landscape {
            headerTopPadding = 2
            artworkTopSpacing = 2
            metadataTopSpacing = 0
            progressTopSpacing = 4
            controlsTopSpacing = 4
            quickActionsTopSpacing = 4
            artworkRatio = 0.55
        } else {
            headerTopPadding = portraitValue(4, 10)
            artworkTopSpacing = portraitValue(8, 20)
            metadataTopSpacing = portraitValue(8, 12)
            progressTopSpacing = portraitValue(6, 10)
            controlsTopSpacing = portraitValue(4, 9)
            quickActionsTopSpacing = portraitValue(6, 8)
            artworkRatio = portraitValue(0.35, 0.42)
        }

        let primaryControlsHeight: CGFloat = 60
        let axExtra = usesAccessibilityText
            ? CGFloat(max(accessibilityStep, 1) - 1) * 14
            : 0
        let quickActionsHeight: CGFloat =
            (usesAccessibilityText ? 72 : 64) + axExtra * 0.35
        let bottomPadding = max(
            safeBottom,
            mode == .landscape ? 6 : 10
        )
        let metadataHeight: CGFloat
        if usesAccessibilityText {
            metadataHeight = (hasAlbum ? 100 : 78) + axExtra
        } else {
            metadataHeight = hasAlbum ? 68 : 54
        }
        let progressHeight: CGFloat =
            (usesAccessibilityText ? 45 : 39) + axExtra * 0.2

        let artworkSize: CGFloat
        let minimumContentHeight: CGFloat
        if mode == .landscape {
            let availableMainHeight = max(
                containerSize.height
                    - headerTopPadding
                    - headerHeight
                    - artworkTopSpacing
                    - quickActionsTopSpacing
                    - quickActionsHeight
                    - bottomPadding,
                0
            )
            let rightColumnMinimum =
                metadataHeight
                + progressTopSpacing
                + progressHeight
                + controlsTopSpacing
                + primaryControlsHeight
            artworkSize = max(
                min(
                    min(
                        contentWidth * 0.36,
                        containerSize.height * artworkRatio
                    ),
                    availableMainHeight
                ),
                min(112, availableMainHeight)
            )
            minimumContentHeight =
                headerTopPadding
                + headerHeight
                + artworkTopSpacing
                + max(artworkSize, rightColumnMinimum)
                + quickActionsTopSpacing
                + quickActionsHeight
                + bottomPadding
        } else {
            let fixedWithoutArtwork =
                headerTopPadding
                + headerHeight
                + artworkTopSpacing
                + metadataTopSpacing
                + metadataHeight
                + progressTopSpacing
                + progressHeight
                + controlsTopSpacing
                + primaryControlsHeight
                + quickActionsTopSpacing
                + quickActionsHeight
                + bottomPadding
            let availableArtworkHeight = max(
                containerSize.height - fixedWithoutArtwork,
                0
            )
            // Accessibility 3+ must not crush the cover to make the
            // column fit: keep a 112pt floor and let the screen scroll.
            let artworkFloor: CGFloat =
                usesAccessibilityText && accessibilityStep >= 3
                    ? 112
                    : min(112, availableArtworkHeight)
            artworkSize = max(
                min(
                    min(
                        contentWidth,
                        containerSize.height * artworkRatio
                    ),
                    max(availableArtworkHeight, artworkFloor)
                ),
                artworkFloor
            )
            minimumContentHeight = fixedWithoutArtwork + artworkSize
        }

        return PlayerLayoutMetrics(
            mode: mode,
            usesAccessibilityText: usesAccessibilityText,
            contentWidth: contentWidth,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding,
            headerHeight: headerHeight,
            headerTopPadding: headerTopPadding,
            artworkSize: artworkSize,
            artworkTopSpacing: artworkTopSpacing,
            metadataTopSpacing: metadataTopSpacing,
            progressTopSpacing: progressTopSpacing,
            controlsTopSpacing: controlsTopSpacing,
            primaryControlsHeight: primaryControlsHeight,
            quickActionsTopSpacing: quickActionsTopSpacing,
            quickActionsHeight: quickActionsHeight,
            bottomPadding: bottomPadding,
            landscapeColumnSpacing: mode == .landscape ? 20 : 0,
            minimumContentHeight: minimumContentHeight
        )
    }

    func quickActionsBottomY(containerHeight: CGFloat) -> CGFloat {
        max(containerHeight - bottomPadding, 0)
    }

    func requiresAccessibilityScrolling(containerHeight: CGFloat) -> Bool {
        minimumContentHeight > containerHeight + 0.5
    }

    /// Fitted player: gaps are `Spacer`s that share leftover height.
    /// Scrolling player: gaps are fixed, so a `ScrollView` has a finite
    /// content size instead of growing without a ceiling.
    func usesFlexibleGaps(containerHeight: CGFloat) -> Bool {
        !requiresAccessibilityScrolling(containerHeight: containerHeight)
    }
}

private enum PlayerSheet: Identifiable {
    case queue
    case lyrics(Track)
    case artist(String)
    case playlists(Track)
    case settings
    case actions(Track)

    var id: String {
        switch self {
        case .queue:
            return "queue"
        case let .lyrics(track):
            return "lyrics-\(track.id)"
        case let .artist(artist):
            return "artist-\(artist)"
        case let .playlists(track):
            return "playlists-\(track.id)"
        case .settings:
            return "settings"
        case let .actions(track):
            return "actions-\(track.id)"
        }
    }
}

private enum DeferredPlayerAction {
    case sheet(PlayerSheet)
    case share(Track)
}

struct PlayerActionAvailability: Equatable {
    let canModifyLibrary: Bool
    let canAddToPlaylist: Bool
    let canShare: Bool
    let showsLibraryProgress: Bool
    let showsOfflineControls: Bool

    init(
        hasSession: Bool,
        isUpdatingLibrary: Bool,
        showsOfflineControls: Bool = OfflineDownloadsFeature.showsControls
    ) {
        canModifyLibrary = hasSession && !isUpdatingLibrary
        canAddToPlaylist = hasSession
        canShare = true
        showsLibraryProgress = isUpdatingLibrary
        self.showsOfflineControls = showsOfflineControls
    }
}

enum PlayerActionSheetMetrics {
    static let preferredHeight: CGFloat = 520
    static let minimumTapTarget: CGFloat = 52
}

enum PlayerDismissGesturePolicy {
    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        let vertical = translation.height
        let horizontal = abs(translation.width)
        guard vertical >= 80,
              vertical > horizontal * 1.25 else {
            return false
        }
        return vertical >= 140 || predictedEndTranslation.height >= 120
    }
}

enum PlayerArtworkCarouselPolicy {
    struct Layout: Equatable {
        let centerSize: CGFloat
        let neighborSize: CGFloat
        let neighborOffset: CGFloat
    }

    struct NeighborIndices: Equatable {
        let previous: Int?
        let next: Int?
    }

    static func layout(for artworkSize: CGFloat) -> Layout {
        let safeSize = max(artworkSize, 0)
        let centerSize = safeSize * 0.84
        return Layout(
            centerSize: centerSize,
            neighborSize: centerSize * 0.82,
            neighborOffset: safeSize * 0.5
        )
    }

    static func neighborIndices(
        queueCount: Int,
        currentIndex: Int?,
        repeatMode: RepeatMode
    ) -> NeighborIndices {
        guard queueCount > 1,
              let currentIndex,
              (0..<queueCount).contains(currentIndex) else {
            return NeighborIndices(previous: nil, next: nil)
        }
        let previous: Int?
        if currentIndex > 0 {
            previous = currentIndex - 1
        } else {
            previous = repeatMode == .all ? queueCount - 1 : nil
        }
        let next: Int?
        if currentIndex + 1 < queueCount {
            next = currentIndex + 1
        } else {
            next = repeatMode == .all ? 0 : nil
        }
        return NeighborIndices(previous: previous, next: next)
    }
}

enum PlayerArtworkBackgroundPolicy {
    static let maxPixelSize: CGFloat = 320
    static let blurRadius: CGFloat = 44
}

enum PlayerHeaderMetrics {
    /// Matches the trailing AirPlay + overflow cluster; leading spacer uses
    /// the same width so the centered "now playing" title stays balanced.
    static let sideClusterWidth: CGFloat = 96
    static let titleHorizontalInset: CGFloat = sideClusterWidth + 8
}

enum PlayerQuickAction: String, CaseIterable, Identifiable {
    case lyrics
    case queue
    case playlist
    case share

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .lyrics: "quote.bubble"
        case .queue: "list.bullet"
        case .playlist: "rectangle.stack.badge.plus"
        case .share: "square.and.arrow.up"
        }
    }

    /// Visible dock caption — keep short so four equal columns fit Russian.
    var title: String {
        switch self {
        case .lyrics: "lyrics"
        case .queue: "player.queue"
        case .playlist: "playlist"
        case .share: "share"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .lyrics, .queue, .playlist:
            return title
        case .share:
            return "share_file"
        }
    }
}

private struct PlayerActionsSheet: View {
    let track: Track
    let isInLibrary: Bool
    let offlineState: OfflineTrackState
    let availability: PlayerActionAvailability
    @Binding var equalizerEnabled: Bool
    @Binding var spatialAudioEnabled: Bool
    @Binding var preferHighQuality: Bool
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var systemVolume = SystemVolumeObserver()
    @State private var showsSleepTimerOptions = false
    let onDismiss: () -> Void
    let onLibrary: () -> Void
    let onArtist: () -> Void
    let onPlaylist: () -> Void
    let onShare: () -> Void
    let onCopyLink: () -> Void
    let onOffline: () -> Void
    let onSettings: () -> Void
    let onProcessingRouteHint: () -> Void
    let onDislikeTrack: () -> Void
    let onDislikeArtist: () -> Void
    let onMixFromTrack: () -> Void
    let onSnippet: () -> Void
    let showsMixFeedback: Bool
    let qualityCaption: String

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack {
            ThemeBackground()

            VStack(spacing: 0) {
                header
                    .adaptiveGlass(
                        in: RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        libraryAction

                        sectionTitle("track_actions")
                        LazyVGrid(columns: columns, spacing: 10) {
                            actionTile(
                                "artist",
                                systemImage: "person.wave.2",
                                action: onArtist
                            )
                            actionTile(
                                "add_to_playlist",
                                systemImage: "rectangle.stack.badge.plus",
                                enabled: availability.canAddToPlaylist,
                                action: onPlaylist
                            )
                            actionTile(
                                "share_audio_file",
                                systemImage: "square.and.arrow.up",
                                enabled: availability.canShare,
                                action: onShare
                            )
                            actionTile(
                                "copy_vk_link",
                                systemImage: "link",
                                action: onCopyLink
                            )
                            if availability.showsOfflineControls {
                                actionTile(
                                    offlineTitle,
                                    systemImage: offlineImage,
                                    enabled: offlineState != .downloading,
                                    action: onOffline
                                )
                            }
                            actionTile(
                                "mix_from_track",
                                systemImage: "dot.radiowaves.up.forward",
                                action: onMixFromTrack
                            )
                            actionTile(
                                "snippet",
                                systemImage: "waveform",
                                action: onSnippet
                            )
                            if showsMixFeedback {
                                actionTile(
                                    "dislike",
                                    systemImage: "hand.thumbsdown",
                                    action: onDislikeTrack
                                )
                                actionTile(
                                    "hide_artist",
                                    systemImage: "person.badge.minus",
                                    action: onDislikeArtist
                                )
                            }
                        }

                        sectionTitle("player_audio")
                        Toggle(
                            isOn: $preferHighQuality
                        ) {
                            Label(
                                L10n.text("high_quality"),
                                systemImage: "waveform"
                            )
                        }
                        .padding(.vertical, 4)
                        Text(qualityCaption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)

                        audioControls
                    }
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([
            .height(PlayerActionSheetMetrics.preferredHeight),
            .large
        ])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            L10n.text("stop_playback_in"),
            isPresented: $showsSleepTimerOptions,
            titleVisibility: .visible
        ) {
            Button(L10n.text("sleep.end_of_track")) {
                player.scheduleSleepTimer(.endOfTrack)
                Haptics.success()
            }
            Button(L10n.text("sleep.end_of_queue")) {
                player.scheduleSleepTimer(.endOfQueue)
                Haptics.success()
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(L10n.minutes(minutes)) {
                    player.scheduleSleepTimer(minutes: minutes)
                    Haptics.success()
                }
            }
            if player.sleepTimerMode != nil {
                Button(
                    L10n.text("cancel_timer"),
                    role: .destructive
                ) {
                    player.cancelSleepTimer()
                    Haptics.selection()
                }
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
    }

    private var audioControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(
                    systemName: systemVolume.volume <= 0.001
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill"
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(settings.theme.accent)
                .frame(width: 30, height: 30)
                .background(settings.theme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

                SystemVolumeSlider(
                    tintColor: BubbleGamut.accent(for: settings.theme).uiColor
                )
                .frame(height: 28)
                .accessibilityLabel(L10n.text("volume"))

                Text(
                    Double(systemVolume.volume),
                    format: .percent.precision(.fractionLength(0))
                )
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)

            Divider()
                .padding(.leading, 58)

            Button(action: onSettings) {
                HStack(spacing: 12) {
                    actionRowLabel(
                        "equalizer",
                        systemImage: "waveform"
                    )
                    Spacer()
                    Text(
                        equalizerEnabled
                            ? L10n.text("on")
                            : L10n.text("off")
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityLabel(L10n.text("equalizer"))
            .accessibilityValue(
                equalizerEnabled
                    ? L10n.text("on")
                    : L10n.text("off")
            )

            Divider()
                .padding(.leading, 58)

            Toggle(isOn: spatialAudioBinding) {
                actionRowLabel(
                    "spatial_audio",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .tint(settings.theme.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)

            Divider()
                .padding(.leading, 58)

            Button {
                Haptics.open()
                showsSleepTimerOptions = true
            } label: {
                HStack(spacing: 12) {
                    actionRowLabel(
                        "sleep_timer",
                        systemImage: "moon.zzz"
                    )
                    Spacer()
                    if let endDate = player.sleepTimerEndDate {
                        Text(endDate, style: .timer)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(settings.theme.accent)
                    } else if let mode = player.sleepTimerMode {
                        Text(mode.statusLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(settings.theme.accent)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityLabel(L10n.text("sleep_timer"))
        }
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            )
        )
    }

    private var spatialAudioBinding: Binding<Bool> {
        Binding(
            get: { spatialAudioEnabled },
            set: { newValue in
                let wasEnabled = spatialAudioEnabled
                spatialAudioEnabled = newValue
                if newValue && !wasEnabled {
                    onProcessingRouteHint()
                }
            }
        )
    }

    private func actionRowLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label {
            Text(L10n.text(title))
                .font(.body.weight(.semibold))
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(settings.theme.accent)
                .frame(width: 30, height: 30)
                .background(settings.theme.accent.opacity(0.12), in: Circle())
        }
    }

    private var offlineTitle: String {
        switch offlineState {
        case .remote:
            return "download"
        case .downloading:
            return "downloading_2"
        case .available:
            return "remove_download"
        }
    }

    private var offlineImage: String {
        switch offlineState {
        case .remote:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "checkmark.circle.fill"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncArtwork(url: track.artworkURL, size: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("action.close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var libraryAction: some View {
        Button(
            role: isInLibrary ? .destructive : nil,
            action: onLibrary
        ) {
            HStack(spacing: 12) {
                Image(
                    systemName: isInLibrary
                        ? "heart.slash"
                        : "heart"
                )
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    BubbleGamut.liked(for: settings.theme)
                )
                .frame(width: 34, height: 34)
                .background(
                    BubbleGamut.liked(for: settings.theme)
                        .opacity(0.12),
                    in: Circle()
                )

                Text(
                    L10n.text(
                        isInLibrary
                            ? "remove_from_library"
                            : "add_to_library_2"
                    )
                )
                .font(.body.weight(.semibold))

                Spacer()

                if availability.showsLibraryProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(
                minHeight: PlayerActionSheetMetrics.minimumTapTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .foregroundStyle(Color.primary)
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            ),
            interactive: true,
            tint: BubbleGamut.liked(for: settings.theme).opacity(0.08)
        )
        .disabled(!availability.canModifyLibrary)
        .padding(.top, 14)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.7)
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    private func actionTile(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        settings.theme.accent.opacity(0.12),
                        in: Circle()
                    )
                Text(L10n.text(title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 66, alignment: .topLeading)
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .foregroundStyle(Color.primary)
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            ),
            interactive: true
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(L10n.text(title))
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    let tintColor: UIColor
    let onWillPresent: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWillPresent: onWillPresent)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
        picker.prioritizesVideoDevices = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(
        _ picker: AVRoutePickerView,
        context: Context
    ) {
        context.coordinator.onWillPresent = onWillPresent
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
        picker.delegate = context.coordinator
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onWillPresent: () -> Void

        init(onWillPresent: @escaping () -> Void) {
            self.onWillPresent = onWillPresent
        }

        func routePickerViewWillBeginPresentingRoutes(
            _ routePickerView: AVRoutePickerView
        ) {
            onWillPresent()
        }
    }
}

private struct PlayerControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(settings.theme == .light ? .black : .white)
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.96 : 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

struct AudioProcessingRouteHintBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "airplayaudio")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            Text(L10n.text("audio_processing_may_disable_airplay"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .adaptiveGlass(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func audioProcessingRouteHintOverlay(
        isPresented: Binding<Bool>,
        bottomPadding: CGFloat = 28
    ) -> some View {
        overlay(alignment: .bottom) {
            if isPresented.wrappedValue {
                AudioProcessingRouteHintBanner()
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            .easeInOut(duration: 0.3),
            value: isPresented.wrappedValue
        )
    }
}
