import SwiftUI

struct CatalogView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    /// Highlight only: observing `AudioPlayer` would rebuild the home rails
    /// on every buffering / duration tick. Actions go through
    /// `environment.player`.
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(AppSettings.self) private var settings
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(HomeCatalogStore.self) private var homeCatalog
    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(MixFeedbackStore.self) private var mixFeedback
    @Environment(HomePersonalizationStore.self) private var personalization
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionErrorMessage: String?
    @State private var sharingTrack: Track?
    @State private var selectedAlbum: Album?
    @State private var loadingAlbumTrackID: String?
    @State private var albumLookupTask: Task<Void, Never>?
    @State private var isNextStepLaunching = false
    @State private var pendingHiddenArtist: HomeNextStepCandidate?
    @State private var openingMixID: String?
    @State private var containerWidth: CGFloat = 390
    @State private var topSafeAreaInset: CGFloat = 0
    @State private var nextStepCandidate: HomeNextStepCandidate?

    var body: some View {
        ScrollViewReader { scrollProxy in
            let metrics = HomeMetrics(containerWidth: containerWidth)
            let heroForegroundTopOrigin =
                HomeStageMetrics.resolvedForegroundTopOrigin(
                    reportedTopSafeAreaInset: topSafeAreaInset
                )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                    if settings.homeStageEnabled {
                        HomeStageView(
                            width: containerWidth,
                            horizontalPadding: metrics.horizontalPadding,
                            foregroundTopOrigin: heroForegroundTopOrigin
                        )
                        .id(MainTabScrollDestination.home)
                    } else {
                        welcomeHeader
                            .padding(.top, heroForegroundTopOrigin)
                            .id(MainTabScrollDestination.home)
                    }

                    if let nextStepCandidate {
                        nextStepSection(
                            nextStepCandidate,
                            metrics: metrics
                        )
                    }
                    if homeCatalog.errorMessage != nil,
                       nextStepCandidate == nil,
                       history.entries.isEmpty {
                        retryRow(errorMessage ?? homeCatalog.errorMessage ?? "")
                    }
                    if !history.entries.isEmpty {
                        recentlyPlayedSection(metrics: metrics)
                    }
                    exploreMusicEntry
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, BubbleSpacing.xs)
            }
            // The vertical indicator sat right over the stage's
            // artwork and controls at the top of the scroll — the one
            // place on Home it can't afford to compete for attention.
            .scrollIndicators(.hidden)
            // Read the viewport once from the background. Wrapping the
            // ScrollView in a GeometryReader re-laid the whole Home tree
            // on every scroll frame and is what made Главная feel sticky.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HomeContainerLayoutKey.self,
                        value: HomeContainerLayout(
                            width: proxy.size.width,
                            topSafeAreaInset: proxy.safeAreaInsets.top
                        )
                    )
                }
            }
            .onPreferenceChange(HomeContainerLayoutKey.self) { layout in
                let roundedWidth = layout.width.rounded()
                if roundedWidth > 0,
                   abs(roundedWidth - containerWidth) >= 1 {
                    containerWidth = roundedWidth
                }
                let roundedTop = layout.topSafeAreaInset.rounded()
                if abs(roundedTop - topSafeAreaInset) >= 1 {
                    topSafeAreaInset = roundedTop
                }
            }
            // Applied on the ScrollView so the last shelf clears the iOS 26
            // accessory mini player. The legacy overlay dock already reserves
            // this in `tabScreen`.
            .clearsMiniPlayer()
            // Gives up its own top safe-area reservation so the stage's
            // artwork-derived atmosphere can paint behind the status bar
            // and the compact nav title instead of stopping at a hard
            // edge there. `HomeStageView` (and the plain welcome header)
            // reintroduce that same inset as top padding on their own
            // foreground content, so nothing actually moves under the
            // Dynamic Island — only the background reaches it.
            .ignoresSafeArea(edges: .top)
            .onChange(of: scrollCoordinator.request) { _, request in
                guard request?.destination == .home else { return }
                scrollToTop(scrollProxy, destination: .home)
            }
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("tab.home"))
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .trackShareSheet(track: $sharingTrack)
        .navigationDestination(
            isPresented: Binding(
                get: { selectedAlbum != nil },
                set: { if !$0 { selectedAlbum = nil } }
            )
        ) {
            if let selectedAlbum {
                AlbumDetailView(album: selectedAlbum)
            }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openingMixID != nil },
                set: { if !$0 { openingMixID = nil } }
            )
        ) {
            MixesHubView(focusedMixID: openingMixID)
        }
        .refreshable { await load(force: true) }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            await load()
        }
        .task(id: nextStepRefreshKey) {
            nextStepCandidate = resolveNextStepCandidate()
        }
        // Liked-album mutations update `LikedAlbumsStore` in place. Reloading
        // the whole home snapshot here used to fan out recommendations /
        // mixes / playlists / releases for a single follow tap.
        .onChange(of: environment.mixActionError) { _, error in
            guard let error else { return }
            actionErrorMessage = error
            environment.mixActionError = nil
        }
        // The candidate is recomputed on every body pass; recording it here
        // (rather than inside the computed property) is what makes the
        // "prefer what's already shown" stickiness actually stick instead
        // of just reading its own last write back immediately.
        .onChange(of: nextStepCandidate?.stabilityKey) { _, key in
            if let key {
                personalization.recordShownNextStep(key: key)
            }
        }
        .onChange(of: nextStepCandidate?.artistKey) { _, key in
            if let key {
                personalization.recordShown(artistKey: key)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MusicLibraryEvents.didChangePlaylists
            )
        ) { _ in
            Task { await load(force: true) }
        }
        .alert(
            "could_not_open_album",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .confirmationDialog(
            L10n.text("hide_artist_in_mixes"),
            isPresented: Binding(
                get: { pendingHiddenArtist != nil },
                set: { if !$0 { pendingHiddenArtist = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("hide_artist"), role: .destructive) {
                if let candidate = pendingHiddenArtist {
                    hideNextStepArtist(candidate)
                }
                pendingHiddenArtist = nil
            }
            Button(L10n.text("action.cancel"), role: .cancel) {
                pendingHiddenArtist = nil
            }
        } message: {
            if let candidate = pendingHiddenArtist {
                Text(
                    L10n.format(
                        "hide_artist_in_mixes_confirmation_0",
                        candidate.titleArgument ?? candidate.artistKey ?? ""
                    )
                )
            }
        }
    }

    private func scrollToTop(
        _ proxy: ScrollViewProxy,
        destination: MainTabScrollDestination
    ) {
        if reduceMotion {
            proxy.scrollTo(destination, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo(destination, anchor: .top)
            }
        }
    }

    private var errorMessage: String? {
        actionErrorMessage ?? homeCatalog.errorMessage
    }

    private var nextStepRefreshKey: HomeNextStepRefreshKey {
        HomeNextStepRefreshKey(
            currentTrackID: highlight.currentTrackID,
            queueSource: highlight.queueSource,
            currentArtist: highlight.currentArtist,
            selectedMood: settings.mixMoodPreference,
            historyHeadTrackIDs: history.entries.prefix(24).map(\.track.id),
            mixIDs: homeCatalog.mixes.map(\.id),
            recommendationsEmpty: homeCatalog.recommendations.isEmpty,
            previouslyShownArtistKey: personalization.lastShownArtistKey,
            previouslyShownKey: personalization.lastShownNextStepKey,
            bannedArtistKeys: mixFeedback.bannedArtists.sorted(),
            bannedTrackIDs: mixFeedback.bannedTrackIDs.sorted(),
            librarySignatures: libraryStore.signatures.sorted()
        )
    }

    private func resolveNextStepCandidate() -> HomeNextStepCandidate? {
        HomeNextStepPolicy.select(
            HomeNextStepRequest(
                affinityCandidates: ArtistAffinityPolicy.candidates(
                    history: history.entries,
                    isLiked: { libraryStore.contains($0) },
                    bannedArtistKeys: mixFeedback.bannedArtists,
                    bannedTrackIDs: mixFeedback.bannedTrackIDs
                ),
                previouslyShownArtistKey: personalization.lastShownArtistKey,
                previouslyShownKey: personalization.lastShownNextStepKey,
                mixes: homeCatalog.mixes,
                selectedMood: settings.mixMoodPreference,
                occupancy: HomeNextStepPolicy.occupancy(
                    hasCurrentTrack: highlight.currentTrackID != nil,
                    queueSource: highlight.queueSource,
                    currentArtist: highlight.currentArtist,
                    mixes: homeCatalog.mixes
                ),
                hasCurrentTrack: highlight.currentTrackID != nil,
                hasListeningHistory: !history.entries.isEmpty,
                hasRecommendations: !homeCatalog.recommendations.isEmpty
            )
        )
    }

    private func seedTrack(forArtistKey key: String) -> Track? {
        history.entries.first { entry in
            ArtistCreditDisplay.components(entry.track.artist).contains {
                MixFeedbackPolicy.normalized($0) == key
            }
        }?.track
    }

    private var welcomeHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.55)
                Text(
                    sessionStore.profile?.firstName
                        ?? L10n.text("listener")
                )
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Spacer()
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 38)
                .clipShape(Circle())
                .overlay { Circle().stroke(.primary.opacity(0.12)) }
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: L10n.text("good_morning")
        case 12..<18: L10n.text("good_afternoon")
        case 18..<23: L10n.text("good_evening")
        default: L10n.text("good_night")
        }
    }

    // MARK: - What's Next

    private func nextStepSection(
        _ candidate: HomeNextStepCandidate,
        metrics: HomeMetrics
    ) -> some View {
        let artworkSize = metrics.nextStepWidth
        return VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            PremiumSectionHeader("home_next.title")
            HStack(alignment: .center, spacing: BubbleSpacing.m) {
                nextStepArtwork(candidate, size: artworkSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nextStepTitle(candidate))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text(candidate.subtitleKey))
                        .font(BubbleType.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if candidate.sourceIsSelena {
                        Text(L10n.text("home_next.source.selena"))
                            .font(BubbleType.micro)
                            .foregroundStyle(.tertiary)
                    } else if candidate.kind == .vkMix {
                        Text(L10n.text("home_next.vk.title"))
                            .font(BubbleType.micro)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: BubbleSpacing.s) {
                        nextStepActionButton(candidate)
                        Spacer(minLength: 0)
                        if nextStepHasMenu(candidate) {
                            Menu {
                                nextStepMenu(candidate)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text("more"))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func nextStepTitle(_ candidate: HomeNextStepCandidate) -> String {
        if candidate.kind == .vkMix, let title = candidate.titleArgument {
            return title
        }
        if let argument = candidate.titleArgument {
            return L10n.format(candidate.titleKey, argument)
        }
        return L10n.text(candidate.titleKey)
    }

    @ViewBuilder
    private func nextStepArtwork(
        _ candidate: HomeNextStepCandidate,
        size: CGFloat
    ) -> some View {
        if let mix = nextStepMix(for: candidate) {
            MixArtworkView(
                mix: mix,
                tracks: [],
                size: size,
                cornerRadius: PremiumLayout.artworkRadius(for: size)
            )
        } else if let url = candidate.artworkURL {
            HomeTrackArtwork(url: url, size: size)
        } else {
            nextStepGlyph(candidate, size: size)
        }
    }

    private func nextStepMix(
        for candidate: HomeNextStepCandidate
    ) -> MusicMix? {
        guard let mixID = candidate.mixID else { return nil }
        return homeCatalog.mixes.first { $0.id == mixID }
            ?? (mixID == MusicMix.common.id ? .common : nil)
    }

    private func nextStepGlyph(
        _ candidate: HomeNextStepCandidate,
        size: CGFloat
    ) -> some View {
        let role: BubbleRole = switch candidate.kind {
        case .artistContinuation: .artist
        case .vibeContinuation: .mood
        case .vkMix: .mix
        case .personalStation: .station
        }
        let tint = BubblePalette.surface(role, tint: nil).color
        return ZStack {
            LinearGradient(
                colors: [tint, tint.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: candidate.kind == .artistContinuation
                ? "person.wave.2.fill"
                : "sparkles")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size),
                style: .continuous
            )
        )
    }

    private func nextStepActionButton(
        _ candidate: HomeNextStepCandidate
    ) -> some View {
        Button {
            launchNextStep(candidate)
        } label: {
            ZStack {
                Text(L10n.text(candidate.actionKey))
                    .opacity(isNextStepLaunching ? 0 : 1)
                if isNextStepLaunching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(minWidth: 92)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isNextStepLaunching)
    }

    private func nextStepHasMenu(_ candidate: HomeNextStepCandidate) -> Bool {
        candidate.artistKey != nil || candidate.kind == .vkMix
    }

    @ViewBuilder
    private func nextStepMenu(_ candidate: HomeNextStepCandidate) -> some View {
        if candidate.artistKey != nil {
            Button {
                suppressNextStep(candidate, includeArtist: false)
            } label: {
                Label(
                    L10n.text("home_next.less_like_this"),
                    systemImage: "hand.thumbsdown"
                )
            }
            Button(role: .destructive) {
                pendingHiddenArtist = candidate
            } label: {
                Label(
                    L10n.text("home_next.hide_artist"),
                    systemImage: "person.badge.minus"
                )
            }
        }
        if let mixID = candidate.mixID, candidate.kind == .vkMix {
            Button {
                openingMixID = mixID
            } label: {
                Label(L10n.text("open_mix"), systemImage: "square.stack")
            }
        }
    }

    private func launchNextStep(_ candidate: HomeNextStepCandidate) {
        guard !isNextStepLaunching else { return }
        Haptics.selection()
        isNextStepLaunching = true
        Task {
            defer { isNextStepLaunching = false }
            switch candidate.action {
            case let .artist(name, artistKey):
                await environment.startMixFromArtist(
                    named: name,
                    seed: seedTrack(forArtistKey: artistKey)
                )
            case .personalStation:
                await environment.startPersonalStation(in: homeCatalog.mixes)
            case let .mood(mood):
                await environment.startMoodStation(
                    mood,
                    in: homeCatalog.mixes
                )
            case let .mix(id):
                if let mix = homeCatalog.mixes.first(where: { $0.id == id }) {
                    await environment.startCatalogMix(mix)
                }
            }
        }
    }

    private func suppressNextStep(
        _ candidate: HomeNextStepCandidate,
        includeArtist: Bool
    ) {
        Haptics.selection()
        if let artistKey = candidate.artistKey,
           let seed = seedTrack(forArtistKey: artistKey) {
            mixFeedback.ban(seed, includeArtist: includeArtist)
            if includeArtist {
                personalization.clearIfShowing(artistKey: artistKey)
            }
        }
        personalization.clearNextStepIfShowing(key: candidate.stabilityKey)
    }

    private func hideNextStepArtist(_ candidate: HomeNextStepCandidate) {
        suppressNextStep(candidate, includeArtist: true)
    }

    private var exploreMusicEntry: some View {
        NavigationLink {
            MixesHubView(
                deprioritizedMixID: nextStepCandidate?.mixID,
                startsOnVK: nextStepCandidate?.kind == .personalStation
            )
        } label: {
            HStack(spacing: BubbleSpacing.s) {
                Text(L10n.text("explore_music"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityHint(L10n.text("explore_music"))
    }

    private func recentlyPlayedSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            PremiumSectionHeader(
                "recently_played",
                subtitle: "history_is_stored_only_on_this_device"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: metrics.cardSpacing
                ) {
                    ForEach(history.entries.prefix(5)) { entry in
                        homeTrackItem(
                            entry.track,
                            queue: history.entries.map(\.track),
                            artworkSize: metrics.recentWidth,
                            source: .history
                        )
                        .contextMenu {
                            trackContextMenu(
                                entry.track,
                                queue: history.entries.map(\.track),
                                source: .history
                            )
                        }
                    }
                }
            }
        }
    }

    private func homeTrackCard(
        _ track: Track,
        artworkSize: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeTrackArtwork(
                url: track.artworkURL,
                size: artworkSize
            )
            .overlay(alignment: .topTrailing) {
                LikedTrackBadge(track: track, style: .artwork)
                    .padding(7)
            }
            Text(track.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(
                    highlight.isCurrent(track.id)
                        ? settings.theme.accent
                        : Color.primary
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(track.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: artworkSize, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func homeTrackItem(
        _ track: Track,
        queue: [Track],
        artworkSize: CGFloat,
        source: QueueSource? = nil
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Button {
                openAlbum(for: track)
            } label: {
                homeTrackCard(track, artworkSize: artworkSize)
            }
            .buttonStyle(PremiumPressStyle())
            .disabled(loadingAlbumTrackID == track.id)

            if loadingAlbumTrackID == track.id {
                ProgressView()
                    .tint(.white)
                    .frame(width: artworkSize, height: artworkSize)
                    .background(.black.opacity(0.18))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius:
                                PremiumLayout.artworkRadius(for: artworkSize),
                            style: .continuous
                        )
                    )
                    .allowsHitTesting(false)
            }

            Button {
                Haptics.selection()
                environment.player.play(track, in: queue, source: source)
            } label: {
                Group {
                    if highlight.isCurrent(track.id) {
                        PlaybackIndicatorView(
                            isPlaying: highlight.isPlaying,
                            color: settings.theme.buttonForeground
                        )
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(settings.theme.buttonForeground)
                .frame(width: 32, height: 32)
                .background(settings.theme.accent, in: Circle())
            }
            .buttonStyle(PremiumPressStyle())
            .offset(x: artworkSize - 39, y: artworkSize - 39)
            .accessibilityLabel(L10n.text("play_track"))
        }
        .frame(width: artworkSize, alignment: .topLeading)
    }

    private func openAlbum(for track: Track) {
        albumLookupTask?.cancel()
        albumLookupTask = nil
        loadingAlbumTrackID = nil
        if let reference = track.albumReference {
            let provisional = reference.album(
                title: Album.isUsableTitle(track.albumTitle)
                    ? track.albumTitle ?? ""
                    : "",
                artist: track.artist,
                artworkURL: track.artworkURL
            )
            if !AlbumAccessPolicy.needsAccessKeyResolution(provisional) {
                selectedAlbum = provisional
                return
            }
            // Community albums from recommendations often omit access_key —
            // resolve it before pushing AlbumDetailView so the first load
            // does not hit "access to users audio is denied".
            loadingAlbumTrackID = track.id
            let requestedTrackID = track.id
            albumLookupTask = Task {
                defer {
                    if loadingAlbumTrackID == requestedTrackID {
                        loadingAlbumTrackID = nil
                        albumLookupTask = nil
                    }
                }
                do {
                    let enriched = try await environment.withAuthorizedToken {
                        token in
                        try await environment.musicService.resolvedAlbum(
                            provisional,
                            accessToken: token
                        )
                    }
                    try Task.checkCancellation()
                    guard loadingAlbumTrackID == requestedTrackID else {
                        return
                    }
                    selectedAlbum = enriched
                    actionErrorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard loadingAlbumTrackID == requestedTrackID else {
                        return
                    }
                    // Still open the provisional album — AlbumDetailView /
                    // albumTracks will retry resolution on load.
                    selectedAlbum = provisional
                }
            }
            return
        }
        guard let title = track.albumTitle,
              Album.isUsableTitle(title) else {
            actionErrorMessage = L10n.text(
                "vk_did_not_return_album_data_for_this_track"
            )
            return
        }
        loadingAlbumTrackID = track.id
        let requestedTrackID = track.id
        albumLookupTask = Task {
            defer {
                if loadingAlbumTrackID == requestedTrackID {
                    loadingAlbumTrackID = nil
                    albumLookupTask = nil
                }
            }
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.searchAlbums(
                        query: title,
                        accessToken: token,
                        offset: 0,
                        count: 20
                    )
                }
                let exact = page.items.first {
                    $0.title.localizedCaseInsensitiveCompare(title)
                        == .orderedSame
                        && ($0.artists.isEmpty
                            || $0.artistText.localizedCaseInsensitiveContains(
                                track.artist
                            ))
                }
                try Task.checkCancellation()
                guard loadingAlbumTrackID == requestedTrackID else {
                    return
                }
                guard let album = exact else {
                    throw APIError.invalidResponse
                }
                selectedAlbum = album
                actionErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = L10n.format(
                    "could_not_open_album_0",
                    error.localizedDescription
                )
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(
        _ track: Track,
        queue: [Track],
        source: QueueSource? = nil
    ) -> some View {
        Button {
            environment.player.playNext(track)
        } label: {
            Label(L10n.text("play_next"), systemImage: "text.badge.plus")
        }
        Button {
            environment.player.playLast(track)
        } label: {
            Label(L10n.text("play_last"),
                systemImage: "text.line.last.and.arrowtriangle.forward"
            )
        }
        Button {
            environment.player.play(track, in: queue, source: source)
            environment.player.presentPlayer()
        } label: {
            Label(L10n.text("open_player"), systemImage: "play.circle")
        }
        TrackMixActions.menuButtons(
            for: track,
            environment: environment
        )
        Button {
            sharingTrack = track
        } label: {
            Label(L10n.text("share_audio_file"), systemImage: "square.and.arrow.up")
        }
    }

    private func retryRow(_ message: String) -> some View {
        Button { Task { await load(force: true) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(14)
            .premiumCard(interactive: true)
        }
        .buttonStyle(PremiumPressStyle())
    }

    private func load(force: Bool = false) async {
        await environment.refreshHomeCatalog(force: force)
    }
}

private struct HomeContainerLayout: Equatable {
    var width: CGFloat = 0
    var topSafeAreaInset: CGFloat = 0
}

private struct HomeContainerLayoutKey: PreferenceKey {
    static var defaultValue: HomeContainerLayout { HomeContainerLayout() }

    static func reduce(
        value: inout HomeContainerLayout,
        nextValue: () -> HomeContainerLayout
    ) {
        value = nextValue()
    }
}

struct HomeMetrics {
    let containerWidth: CGFloat

    var horizontalPadding: CGFloat {
        AdaptiveLayout.horizontalPadding(for: containerWidth)
    }

    var cardSpacing: CGFloat {
        containerWidth <= 350 ? 10 : 12
    }

    var nextStepWidth: CGFloat {
        BubbleMetrics.clamp(
            containerWidth * 0.18,
            minimum: 64,
            maximum: 76
        )
    }

    var recentWidth: CGFloat {
        AdaptiveLayout.shelfCardWidth(
            for: containerWidth,
            compactMax: 126,
            regularMax: AdaptiveLayout.regularCardWidthCap,
            fraction: 0.33,
            compactMin: 108
        )
    }

}

private struct HomeTrackArtwork: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let url: URL?
    let size: CGFloat

    var body: some View {
        CachedRemoteImage(
            url: url,
            maxPixelSize: ArtworkDecodePolicy.maxPixelSize(
                displayPoints: size,
                scale: displayScale
            )
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [
                        settings.theme.surface,
                        settings.theme.secondaryAccent.opacity(0.48)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.22, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size),
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size),
                style: .continuous
            )
            .stroke(.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}
