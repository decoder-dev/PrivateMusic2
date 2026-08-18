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
    @Environment(PlaybackHighlightModel.self) private var highlight
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
    /// The resolved top origin the Hero foreground must respect. `CatalogView`
    /// resolves this once from the top chrome boundary plus Home's own
    /// breathing gap, so the Hero block never starts underneath "Главная".
    let foregroundTopOrigin: CGFloat

    private var presentation: HomeStagePresentation {
        HomeStagePresentation.resolve(
            hasCurrentTrack: highlight.currentTrackID != nil
        )
    }

    private var stageMotion: Animation? {
        BubbleMotion.state(reduceMotion: reduceMotion)
    }

    private var showsContextRail: Bool {
        HomeStageContextBuilder.resolveRailContexts(
            hasCurrentTrack: highlight.currentTrackID != nil,
            queueSource: highlight.queueSource,
            currentArtist: highlight.currentArtist,
            mixes: homeCatalog.mixes,
            historyEntries: history.entries,
            selectedMood: settings.mixMoodPreference,
            stationTitle: L10n.text("selena.name")
        ).isEmpty == false
    }

    var body: some View {
        VStack(spacing: 0) {
            contextChip
                .frame(height: HomeStageMetrics.chipHeight)
                .padding(.bottom, HomeStageMetrics.belowChip)
                .animation(stageMotion, value: presentation)

            headline
                .padding(.bottom, HomeStageMetrics.belowHeadline)
                .animation(stageMotion, value: presentation)

            artwork
                .padding(.bottom, HomeStageMetrics.belowArtwork)
                .animation(stageMotion, value: presentation)

            controls
                .padding(
                    .bottom,
                    showsContextRail
                        ? HomeStageMetrics.belowTransport
                        : BubbleSpacing.m
                )
                .animation(stageMotion, value: presentation)

            HomeStageBubbleRail(
                width: width,
                horizontalPadding: horizontalPadding,
                startingContextID: startingContextID,
                onStart: start
            )
        }
        .padding(.top, foregroundTopOrigin)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            HomeStageAtmosphereLayer(
                width: width,
                horizontalPadding: horizontalPadding,
                foregroundTopOrigin: foregroundTopOrigin
            )
        }
        .task(id: highlight.currentTrackID) { syncLibraryState() }
        .onChange(of: libraryStore.signatures) { _ in syncLibraryState() }
        .onDisappear { launchTask?.cancel() }
    }

    // MARK: - Chip

    @ViewBuilder
    private var contextChip: some View {
        if highlight.currentTrackID != nil {
            BubbleChip(title: highlight.queueContextTitle ?? "") {
                Button {
                    Haptics.selection()
                    environment.player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(GravityTokens.brand)
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
        guard let title = highlight.currentTrackTitle else {
            return L10n.text("selena.name")
        }
        let artist = highlight.currentArtist?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !artist.isEmpty else { return title }
        return ArtistCreditDisplay.readable(artist)
    }

    // MARK: - Artwork

    private var artwork: some View {
        let size = HomeStageMetrics.artworkSize(for: width)
        return Group {
            if highlight.currentTrackID != nil {
                CachedRemoteImage(
                    url: highlight.currentTrackArtworkURL,
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
                GravityActionButton(
                    systemImage: highlight.isPlaying
                        ? "pause.fill"
                        : "play.fill",
                    height: height,
                    accessibilityLabel: L10n.text(
                        highlight.isPlaying ? "pause" : "resume_playback"
                    )
                ) {
                    Haptics.selection()
                    environment.player.playPause()
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

    /// Flat on purpose: Play is a Gravity action and Like stays a glass
    /// heart, but the title between them is a label, not its own surface
    /// — a third glass pill made three unrelated objects out of one
    /// playback group.
    private func nowPlayingTitle(height: CGFloat) -> some View {
        Button {
            Haptics.open()
            environment.player.presentPlayer()
        } label: {
            Text(highlight.currentTrackTitle ?? "")
                .font(BubbleType.cardTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel(highlight.currentTrackTitle ?? "")
        .accessibilityHint(L10n.text("open_full_screen_player"))
    }

    private var stationContext: HomeStageContext {
        HomeStageContext(
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
        guard let id = highlight.currentTrackID else { return false }
        return pendingLibraryTrackIDs.contains(id)
    }

    private func syncLibraryState() {
        guard let track = environment.player.currentTrack else {
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
        guard let track = environment.player.currentTrack,
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
                guard environment.player.currentTrack?.id == trackID else { return }
                syncLibraryState()
            } catch is CancellationError {
                guard environment.player.currentTrack?.id == trackID else { return }
                isInLibrary = removing
            } catch {
                guard environment.player.currentTrack?.id == trackID else { return }
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
