import SwiftUI

/// The Home hero. A compact block at the top of the page — what is
/// playing, one clear action, and the contexts you can jump into — with
/// the shelves already starting underneath inside the first viewport.
///
/// Deliberately not a second player: the full player owns large artwork
/// and the complete transport, this owns orientation.
struct HomeStageView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(HomeCatalogStore.self) private var homeCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isInLibrary = false
    /// Tracks with a library mutation in flight. A set rather than one id:
    /// liking track A and skipping to B must leave B's heart tappable, and
    /// A's reply must not repaint it.
    @State private var pendingLibraryTrackIDs: Set<String> = []
    @State private var startingContextID: String?
    /// One launch at a time. A second tap cancels the first so two radio
    /// requests cannot finish out of order and fight over the queue.
    @State private var launchTask: Task<Void, Never>?

    let width: CGFloat
    /// Home's grid inset. The stage keeps its content on that grid and
    /// lets only the decorative layers cross it.
    let horizontalPadding: CGFloat
    /// The status bar / nav bar reservation above the stage, read once from
    /// Home's own `GeometryReader` — not a magic number, and not something
    /// the stage can find itself while sitting inside scrollable content.
    /// The atmosphere uses it to bleed its background past the safe area;
    /// none of the foreground content changes position because of it.
    let topSafeAreaInset: CGFloat

    private var presentation: HomeStagePresentation {
        HomeStagePresentation.resolve(
            hasCurrentTrack: player.currentTrack != nil
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Bleeds behind the status bar / nav bar — the container this
            // stage sits in has already given up its own top safe-area
            // reservation (see `CatalogView`), so this is free to paint
            // there. The foreground column below carries its own matching
            // padding to land exactly where it always has.
            atmosphere

            VStack(spacing: 0) {
                contextChip
                    .frame(height: HomeStageMetrics.chipHeight)
                    .padding(.bottom, HomeStageMetrics.belowChip)

                headline
                    .padding(.bottom, HomeStageMetrics.belowHeadline)

                artwork
                    .padding(.bottom, HomeStageMetrics.belowArtwork)

                controls
                    .padding(.bottom, HomeStageMetrics.belowTransport)

                bubbleRail
            }
            .padding(.top, topSafeAreaInset)
            .frame(maxWidth: .infinity)
        }
        .animation(
            BubbleMotion.state(reduceMotion: reduceMotion),
            value: presentation
        )
        .task(id: player.currentTrack?.id) { syncLibraryState() }
        .onChange(of: libraryStore.signatures) { _ in syncLibraryState() }
        .onDisappear { launchTask?.cancel() }
    }

    // MARK: - Atmosphere

    /// The blurred-artwork treatment the player already uses, bounded to
    /// the hero and masked to nothing at its base so there is no seam
    /// where the shelves begin.
    ///
    /// Keyed on the artwork URL rather than the track, and never animated:
    /// Home is on screen constantly, and redecoding here on every playback
    /// tick is exactly what put this app on the heat path once already.
    private var atmosphere: some View {
        ZStack {
            if let artworkURL = player.currentTrack?.artworkURL {
                CachedRemoteImage(
                    url: artworkURL,
                    maxPixelSize: PlayerArtworkBackgroundPolicy.maxPixelSize
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(
                            radius: PlayerArtworkBackgroundPolicy.blurRadius
                        )
                        .saturation(1.15)
                        // A tint the status/artist/artwork/controls sit in,
                        // not a wallpaper behind them — 0.78 read as a
                        // second background, 0.58 read as a weak glow
                        // localized behind the artwork instead of one field
                        // the whole hero sits in.
                        .opacity(settings.theme == .light ? 0.22 : 0.64)
                } placeholder: {
                    Color.clear
                }
                .id(artworkURL)
            } else {
                // Idle still gets a whisper of the station's own colour
                // instead of flat black — the same role palette the idle
                // artwork glyph already draws from, not a second engine.
                idleAtmosphereTint
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: HomeStageMetrics.atmosphereHeight(
                for: width,
                topSafeAreaInset: topSafeAreaInset
            )
        )
        .clipped()
        // Fades to nothing, not to a colour, so it dissolves into whatever
        // ThemeBackground is painting underneath instead of ending on a
        // rectangle.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.8), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.horizontal, -horizontalPadding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var idleAtmosphereTint: some View {
        let tint = BubblePalette.surface(.station, tint: nil).color
        return LinearGradient(
            colors: [
                tint.opacity(settings.theme == .light ? 0.10 : 0.20),
                .clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Chip

    @ViewBuilder
    private var contextChip: some View {
        if player.currentTrack != nil {
            BubbleChip(title: player.queueContextTitle) {
                Button {
                    Haptics.selection()
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                        .frame(width: 22, height: 22)
                        // The glyph stays small so the chip stays a status,
                        // not a button; the hit area still clears 44×44 by
                        // growing only the tap region, not the layout.
                        .contentShape(Circle().inset(by: -11))
                }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel(L10n.text("home_stage.clear_queue"))
            }
        } else {
            // Quieter when idle: the call to action below is the thing to
            // look at, not the status.
            BubbleChip(
                title: L10n.text("home_stage.nothing_playing"),
                isProminent: false
            )
        }
    }

    // MARK: - Headline

    private var headline: some View {
        Text(headlineText)
            .font(BubbleType.hero(HomeStageMetrics.headlineSize(for: width)))
            .tracking(-0.4)
            .lineLimit(2)
            // Shrinking is the fallback, not the strategy: the band this
            // reads from is already narrow (32–38 pt), so a short name
            // never needs to reach for it.
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    private var headlineText: String {
        guard let track = player.currentTrack else {
            return L10n.text("selena.name")
        }
        let artist = track.artist.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !artist.isEmpty else { return track.title }
        return ArtistCreditDisplay.readable(artist)
    }

    // MARK: - Artwork

    private var artwork: some View {
        let size = HomeStageMetrics.artworkSize(for: width)
        return Group {
            if let track = player.currentTrack {
                CachedRemoteImage(
                    url: track.artworkURL,
                    maxPixelSize: size * 3
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    stationArtwork(size: size)
                }
            } else {
                stationArtwork(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: BubbleRadius.artwork(for: size),
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(settings.theme == .dark ? 0.34 : 0.16),
            radius: 16,
            y: 8
        )
        .accessibilityHidden(true)
    }

    /// Idle gets a generated station bubble rather than a grey rectangle —
    /// compact, but something to look at.
    private func stationArtwork(size: CGFloat) -> some View {
        let tint = BubblePalette.surface(.station, tint: nil).color
        return ZStack {
            LinearGradient(
                colors: [tint, tint.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    // MARK: - Controls

    /// Playing: transport, title, like. Idle: exactly one call to action.
    /// The idle screen used to carry a play button, a big pill and a
    /// disabled heart — three controls for a single possible action.
    @ViewBuilder
    private var controls: some View {
        let height = HomeStageMetrics.controlHeight(for: width)
        if presentation.showsCallToAction {
            BubbleCallToAction(
                title: L10n.text("home_stage.start_station"),
                height: height,
                isBusy: startingContextID != nil
            ) {
                start(stationContext)
            }
        } else {
            HStack(spacing: BubbleSpacing.s) {
                BubbleIconButton(
                    systemImage: player.isPlaying
                        ? "pause.fill"
                        : "play.fill",
                    size: height,
                    accessibilityLabel: L10n.text(
                        player.isPlaying ? "pause" : "resume_playback"
                    )
                ) {
                    Haptics.selection()
                    player.playPause()
                }

                nowPlayingTitle(height: height)

                if presentation.showsHeart {
                    BubbleIconButton(
                        systemImage: isInLibrary ? "heart.fill" : "heart",
                        size: height,
                        isActive: isInLibrary,
                        isEnabled: !isMutatingCurrentTrack,
                        accessibilityLabel: L10n.text(
                            isInLibrary
                                ? "track_is_in_your_library"
                                : "track_is_not_in_your_library"
                        )
                    ) {
                        toggleLibrary()
                    }
                }
            }
        }
    }

    /// Flat on purpose: Play and Like on either side are genuine floating
    /// controls and keep their glass, but the title between them is a
    /// label, not its own surface — a third glass pill made three
    /// unrelated objects out of one playback group.
    private func nowPlayingTitle(height: CGFloat) -> some View {
        Button {
            Haptics.open()
            player.presentPlayer()
        } label: {
            Text(player.currentTrack?.title ?? "")
                .font(BubbleType.cardTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel(player.currentTrack?.title ?? "")
        .accessibilityHint(L10n.text("open_full_screen_player"))
    }

    // MARK: - Context rail

    private var contexts: [HomeStageContext] {
        HomeStageContextBuilder.build(
            mixes: homeCatalog.mixes,
            recentArtists: HomeStageContextBuilder.recentArtists(
                from: history.entries
            ),
            selectedMood: settings.mixMoodPreference,
            stationTitle: L10n.text("selena.name")
        )
    }

    private var stationContext: HomeStageContext {
        contexts.first { $0.kind == .station }
            ?? HomeStageContext(
                id: "station",
                kind: .station,
                name: L10n.text("selena.name"),
                priority: .primary,
                avatarURL: nil,
                mixID: nil,
                mood: nil,
                artist: nil
            )
    }

    /// Tiles are shown whole. The rail used to shrink its own frame to
    /// fake bubbles rising off the bottom edge, which on a device simply
    /// read as clipping. Running past the screen edges horizontally is the
    /// decorative part; `contentMargins` keeps the first tile on Home's
    /// grid and lets the last one scroll fully clear.
    private var bubbleRail: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: BubbleSpacing.m) {
                ForEach(contexts) { context in
                    bubble(context)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.leading, horizontalPadding, for: .scrollContent)
        .contentMargins(
            .trailing,
            horizontalPadding + BubbleMetrics.railTrailingInset(for: width),
            for: .scrollContent
        )
        .frame(height: HomeStageMetrics.railHeight(for: width))
        .padding(.horizontal, -horizontalPadding)
    }

    /// A shortcut, not a second hero: soft geometry, contextual colour and
    /// compact grouping rather than a circle sized to compete with the
    /// artwork above it. Height is uniform across the rail — only width
    /// (and, faintly, colour) carries priority.
    private func bubble(_ context: HomeStageContext) -> some View {
        let tileHeight = HomeStageMetrics.railHeight(for: width)
        let tileWidth = BubbleMetrics.contextTileWidth(
            for: width,
            priority: context.priority
        )
        let glyphSize = BubbleMetrics.contextGlyphSize(for: tileHeight)
        let shape = RoundedRectangle(
            cornerRadius: BubbleRadius.contextTile,
            style: .continuous
        )
        // Artwork-derived tints come from the shared cache once one has
        // been sampled; the role palette is the guaranteed fallback, so the
        // rail never loses its colour legend.
        let fill = BubblePalette.surface(
            context.kind.role,
            tint: BubbleTintCache.shared.cached(for: context.avatarURL)
        )
        return Button {
            start(context)
        } label: {
            HStack(spacing: BubbleSpacing.s) {
                bubbleGlyph(context, size: glyphSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.kind.kicker)
                        .font(BubbleType.bubbleKicker)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text(context.displayName)
                        .font(BubbleType.bubbleTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.88)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BubbleSpacing.m)
            .frame(width: tileWidth, height: tileHeight, alignment: .leading)
            .bubbleSurface(shape, fill: .solid(fill), elevation: .resting)
            .overlay {
                if startingContextID == context.id {
                    ZStack {
                        shape.fill(.black.opacity(0.28))
                        ProgressView().tint(.white)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(BubblePressStyle())
        .frame(minHeight: BubbleMetrics.minimumTapTarget)
        // One element, one sentence — not image, then kicker, then name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// A real photo earns its own circle; the symbol fallback sits directly
    /// on the tile's own tinted surface. Wrapping the fallback in a second
    /// filled circle was a bubble stacked inside a bubble for no reason —
    /// the tile is already the coloured surface.
    @ViewBuilder
    private func bubbleGlyph(
        _ context: HomeStageContext,
        size: CGFloat
    ) -> some View {
        if let avatarURL = context.avatarURL {
            CachedRemoteImage(url: avatarURL, maxPixelSize: size * 3) {
                image in
                image.resizable().scaledToFill()
            } placeholder: {
                glyphFallback(context, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 1) }
        } else {
            glyphFallback(context, size: size)
        }
    }

    private func glyphFallback(
        _ context: HomeStageContext,
        size: CGFloat
    ) -> some View {
        Image(systemName: context.kind.symbol)
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
    }

    // MARK: - Launching

    /// Every bubble launches through here, and every launch cancels the
    /// one before it. Tapping an artist and then a mood must leave the
    /// mood playing, whichever network call happens to finish last.
    private func start(_ context: HomeStageContext) {
        Haptics.selection()
        launchTask?.cancel()
        if let mood = context.mood {
            settings.mixMoodPreference = mood
        }
        startingContextID = context.id
        launchTask = Task { @MainActor in
            defer {
                if startingContextID == context.id {
                    startingContextID = nil
                }
            }
            switch context.kind {
            case .mix:
                if let mixID = context.mixID,
                   let mix = homeCatalog.mixes.first(
                       where: { $0.id == mixID }
                   ) {
                    await environment.startCatalogMix(mix)
                } else {
                    await environment.startPersonalStation(
                        in: homeCatalog.mixes
                    )
                }
            case .vibe:
                await environment.startMoodStation(
                    context.mood ?? settings.mixMoodPreference,
                    in: homeCatalog.mixes
                )
            case .artist:
                guard let artist = context.artist else { return }
                await environment.startMixFromArtist(
                    named: artist.name,
                    seed: artist.seed
                )
            case .station:
                await environment.startPersonalStation(in: homeCatalog.mixes)
            }
        }
    }

    // MARK: - Library

    /// Only the current track's own in-flight mutation disables its heart.
    private var isMutatingCurrentTrack: Bool {
        guard let id = player.currentTrack?.id else { return false }
        return pendingLibraryTrackIDs.contains(id)
    }

    private func syncLibraryState() {
        guard let track = player.currentTrack else {
            isInLibrary = false
            return
        }
        isInLibrary = libraryStore.contains(track)
            || track.ownerID == sessionStore.session?.userID
    }

    /// Optimistic, and tied to the track it started on. A slow response
    /// for the previous track must not repaint the heart of the one now
    /// playing.
    private func toggleLibrary() {
        guard let track = player.currentTrack,
              sessionStore.accessToken != nil,
              !pendingLibraryTrackIDs.contains(track.id) else {
            return
        }
        let trackID = track.id
        let removing = isInLibrary
        pendingLibraryTrackIDs.insert(trackID)
        isInLibrary = !removing
        Task { @MainActor in
            defer { pendingLibraryTrackIDs.remove(trackID) }
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
                }
                Haptics.selection()
                guard player.currentTrack?.id == trackID else { return }
                syncLibraryState()
            } catch is CancellationError {
                guard player.currentTrack?.id == trackID else { return }
                isInLibrary = removing
            } catch {
                guard player.currentTrack?.id == trackID else { return }
                isInLibrary = removing
                environment.mixActionError = L10n.format(
                    removing
                        ? "could_not_remove_the_track_0"
                        : "could_not_add_the_track_0",
                    error.localizedDescription
                )
            }
        }
    }
}
