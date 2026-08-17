import SwiftUI

/// The Home hero: what is playing, big, with the ways back into listening
/// underneath it. Everything below it on Home stays exactly as it was —
/// this sits on top of the existing shelves rather than replacing them.
struct HomeStageView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(HomeCatalogStore.self) private var homeCatalog

    @State private var isInLibrary = false
    @State private var isUpdatingLibrary = false
    @State private var startingContextID: String?

    let width: CGFloat
    /// Home insets its shelves; the stage spans the full width so the
    /// atmosphere and the bubbles can run off both edges, and re-applies
    /// the inset only to the pieces that must not touch them.
    let horizontalPadding: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            contextChip
                .padding(.bottom, HomeStageViewPadding.belowChip)

            headline
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, HomeStageViewPadding.belowHeadline)

            artwork
                .padding(.bottom, HomeStageViewPadding.belowArtwork)

            transport
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, HomeStageViewPadding.belowTransport)

            bubbleRail
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { atmosphere }
        .task(id: player.currentTrack?.id) { updateLibraryState() }
        .onChange(of: libraryStore.signatures) { _ in updateLibraryState() }
    }

    // MARK: - Atmosphere

    /// The same treatment the player uses for its own background: the
    /// artwork itself, scaled up and blurred past recognition. Collapsed
    /// into one layer by `drawingGroup(opaque:)` and rebuilt only when the
    /// track changes — Home is on screen constantly, so this must not
    /// animate. See `PlayerView.artworkBackground`.
    private var atmosphere: some View {
        ZStack {
            settings.theme.colors.last ?? Color.black
            if let artworkURL = player.currentTrack?.artworkURL {
                CachedRemoteImage(
                    url: artworkURL,
                    maxPixelSize: PlayerArtworkBackgroundPolicy.maxPixelSize
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.4)
                        .blur(
                            radius: PlayerArtworkBackgroundPolicy.blurRadius
                        )
                        .saturation(1.18)
                        .opacity(settings.theme == .light ? 0.3 : 0.92)
                } placeholder: {
                    Color.clear
                }
                .id(player.currentTrack?.id)
            }
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(
                        color: (settings.theme.colors.first ?? .black)
                            .opacity(0.55),
                        location: HomeStageMetrics.atmosphereFadeStart
                    ),
                    .init(
                        color: settings.theme.colors.first ?? .black,
                        location: 1
                    )
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: atmosphereHeight)
        .clipped()
        .drawingGroup(opaque: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var atmosphereHeight: CGFloat {
        HomeStageMetrics.artworkSize(for: width)
            + HomeStageMetrics.controlHeight(for: width)
            + HomeStageMetrics.artistFontSize(for: width) * 2
            + 150
    }

    // MARK: - Chip

    @ViewBuilder
    private var contextChip: some View {
        if player.currentTrack != nil {
            HStack(spacing: 8) {
                Text(player.queueContextTitle)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    Haptics.selection()
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 20, height: 20)
                        .background(.primary.opacity(0.85), in: Circle())
                        .foregroundStyle(settings.theme.colors.first ?? .black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("home_stage.clear_queue"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .adaptiveGlass(in: Capsule(style: .continuous))
        } else {
            Text(L10n.text("home_stage.nothing_playing"))
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .adaptiveGlass(in: Capsule(style: .continuous))
        }
    }

    // MARK: - Headline

    private var headline: some View {
        Text(headlineText)
            .font(
                .system(
                    size: HomeStageMetrics.artistFontSize(for: width),
                    weight: .heavy
                )
            )
            .tracking(-1)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    private var headlineText: String {
        guard let track = player.currentTrack else {
            return L10n.text("selena_station")
        }
        let artist = track.artist.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return artist.isEmpty ? track.title : artist
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artwork: some View {
        let size = HomeStageMetrics.artworkSize(for: width)
        Group {
            if let track = player.currentTrack {
                CachedRemoteImage(
                    url: track.artworkURL,
                    maxPixelSize: size * 3
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.36), radius: 18, y: 8)
        .accessibilityHidden(true)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        let height = HomeStageMetrics.controlHeight(for: width)
        return HStack(spacing: 8) {
            Button {
                Haptics.selection()
                if player.currentTrack == nil {
                    startStation()
                } else {
                    player.playPause()
                }
            } label: {
                Image(
                    systemName: player.isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 17, weight: .bold))
                .frame(width: height, height: height)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(in: Circle(), interactive: true)
            .accessibilityLabel(
                L10n.text(player.isPlaying ? "pause" : "resume_playback")
            )

            Button {
                if player.currentTrack == nil {
                    Haptics.selection()
                    startStation()
                } else {
                    Haptics.open()
                    player.presentPlayer()
                }
            } label: {
                Text(transportTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .adaptiveGlass(
                in: Capsule(style: .continuous),
                interactive: true
            )
            .accessibilityHint(
                L10n.text(
                    player.currentTrack == nil
                        ? "home_stage.start_station"
                        : "open_full_screen_player"
                )
            )

            likeButton(height: height)
        }
    }

    private var transportTitle: String {
        guard let track = player.currentTrack else {
            return L10n.text("home_stage.start_station")
        }
        return track.title
    }

    @ViewBuilder
    private func likeButton(height: CGFloat) -> some View {
        Button {
            guard let track = player.currentTrack else { return }
            toggleLibrary(track)
        } label: {
            Image(systemName: isInLibrary ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: height, height: height)
        }
        .buttonStyle(.plain)
        .adaptiveGlass(in: Circle(), interactive: true)
        .disabled(player.currentTrack == nil || isUpdatingLibrary)
        .opacity(player.currentTrack == nil ? 0.45 : 1)
        .accessibilityLabel(
            L10n.text(
                isInLibrary
                    ? "track_is_in_your_library"
                    : "track_is_not_in_your_library"
            )
        )
    }

    // MARK: - Bubbles

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

    private var bubbleRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(contexts.enumerated()), id: \.element.id) {
                    index, context in
                    bubble(context, index: index)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, HomeStageMetrics.avatarOverhang(for: width))
        }
        // The row is taller than this frame on purpose. ScrollView clips
        // to its bounds, so the bottom of every bubble is cut by the same
        // line while the avatars stay inside the top padding above.
        .frame(height: HomeStageMetrics.railHeight(for: width))
    }

    private func bubble(_ context: HomeStageContext, index: Int) -> some View {
        let size = HomeStageMetrics.bubbleSize(for: width, index: index)
        let avatar = HomeStageMetrics.avatarSize(for: width)
        return Button {
            start(context)
        } label: {
            VStack(spacing: 4) {
                bubbleAvatar(context, size: avatar)
                    .padding(.top, -avatar / 2)
                Text(context.kind.kicker)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(context.name)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(width: size, height: size)
            .background(context.kind.tint, in: Circle())
            .overlay {
                if startingContextID == context.id {
                    ProgressView().tint(.white)
                }
            }
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel("\(context.kind.kicker), \(context.name)")
    }

    private func bubbleAvatar(
        _ context: HomeStageContext,
        size: CGFloat
    ) -> some View {
        Group {
            if let avatarURL = context.avatarURL {
                CachedRemoteImage(url: avatarURL, maxPixelSize: size * 3) {
                    image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    monogram(context)
                }
            } else {
                monogram(context)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.22), lineWidth: 1) }
        .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
        .accessibilityHidden(true)
    }

    private func monogram(_ context: HomeStageContext) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.42))
            Text(context.monogram)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white.opacity(0.86))
        }
    }

    // MARK: - Actions

    private func start(_ context: HomeStageContext) {
        guard startingContextID == nil else { return }
        Haptics.selection()
        if let mood = context.mood {
            settings.mixMoodPreference = mood
        }
        startingContextID = context.id
        Task {
            defer { startingContextID = nil }
            if let mixID = context.mixID,
               let mix = homeCatalog.mixes.first(where: { $0.id == mixID }) {
                await environment.startCatalogMix(mix)
            } else if context.kind == .artist {
                await environment.startMixFromMyMusic()
            } else {
                await startPersonalStation()
            }
        }
    }

    private func startStation() {
        guard startingContextID == nil else { return }
        startingContextID = "station"
        Task {
            defer { startingContextID = nil }
            await startPersonalStation()
        }
    }

    private func startPersonalStation() async {
        if let personal = homeCatalog.mixes.first(
            where: { $0.id == MusicMix.common.id }
        ) {
            await environment.startCatalogMix(personal)
        } else {
            await environment.startMixFromMyMusic()
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
                updateLibraryState()
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
}
