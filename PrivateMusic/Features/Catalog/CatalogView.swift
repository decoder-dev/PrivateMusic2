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
    @State private var isDynamicArtistLaunching = false

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { proxy in
                let metrics = HomeMetrics(containerWidth: proxy.size.width)
                let resolvedForegroundTopInset =
                    HomeStageMetrics.resolvedForegroundTopInset(
                        reportedTopSafeAreaInset: proxy.safeAreaInsets.top
                    )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                        if settings.homeStageEnabled {
                            HomeStageView(
                                width: proxy.size.width,
                                horizontalPadding: metrics.horizontalPadding,
                                topSafeAreaInset: resolvedForegroundTopInset
                            )
                            .id(MainTabScrollDestination.home)
                        } else {
                            welcomeHeader
                                .padding(.top, resolvedForegroundTopInset)
                                .id(MainTabScrollDestination.home)
                        }

                        if !vkMixCandidates.isEmpty {
                            vkMixesSection(metrics: metrics)
                        }
                        if isLoading && contentIsEmpty {
                            catalogSkeleton(metrics: metrics)
                        } else {
                            if !recommendations.isEmpty {
                                recommendationsSection(metrics: metrics)
                            }
                            if contentIsEmpty { unavailableView }
                            if let errorMessage, !contentIsEmpty {
                                retryRow(errorMessage)
                            }
                        }
                        if let dynamicArtistCandidate {
                            dynamicArtistSection(
                                dynamicArtistCandidate,
                                metrics: metrics
                            )
                        }
                        if !history.entries.isEmpty {
                            recentlyPlayedSection(metrics: metrics)
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, BubbleSpacing.xs)
                }
                // The vertical indicator sat right over the stage's
                // artwork and controls at the top of the scroll — the one
                // place on Home it can't afford to compete for attention.
                .scrollIndicators(.hidden)
            }
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
        .refreshable { await load(force: true) }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            await load()
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
        .onChange(of: dynamicArtistCandidate?.artistKey) { _, key in
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

    private var recommendations: [Track] { homeCatalog.recommendations }
    private var featuredRecommendations: [Track] {
        Array(recommendations.prefix(14))
    }
    private var isLoading: Bool { homeCatalog.isRefreshing }
    private var errorMessage: String? {
        actionErrorMessage ?? homeCatalog.errorMessage
    }

    /// Home's own discovery signal, plus the VK mixes and dynamic-artist
    /// sections below — new releases and playlists still belong to
    /// Library, which owns saved content; their emptiness doesn't belong
    /// in this check.
    private var contentIsEmpty: Bool { recommendations.isEmpty }

    /// VK's own feed already comes relevance-ordered — this is dedup and
    /// a cap, not a second ranking model layered on data this app has no
    /// basis to second-guess.
    private var vkMixCandidates: [MusicMix] {
        HomeVKMixesPolicy.candidates(from: homeCatalog.mixes)
    }

    /// The one artist Home's own listening signals currently support,
    /// still respecting whatever `MixFeedbackStore` has suppressed and
    /// preferring the artist already shown so the section does not
    /// reshuffle after every track.
    private var dynamicArtistCandidate: ArtistAffinityCandidate? {
        let candidates = ArtistAffinityPolicy.candidates(
            history: history.entries,
            isLiked: { libraryStore.contains($0) },
            bannedArtistKeys: mixFeedback.bannedArtists
        )
        return ArtistAffinityPolicy.selectDynamicArtist(
            from: candidates,
            previouslyShownKey: personalization.lastShownArtistKey
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

    // MARK: - VK Mixes

    /// Media-first: artwork carries the section, source metadata stays
    /// small. `MixesHubView` still owns the full catalog and advanced
    /// Radio tuning — this is a taste, not a second copy of that screen.
    private func vkMixesSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                PremiumSectionHeader("vk_mixes")
                Spacer(minLength: BubbleSpacing.m)
                NavigationLink(L10n.text("all_mixes")) {
                    MixesHubView()
                }
                .font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(vkMixCandidates) { mix in
                        vkMixCard(mix, artworkSize: metrics.trackWidth)
                    }
                }
            }
        }
    }

    private func vkMixCard(
        _ mix: MusicMix,
        artworkSize: CGFloat
    ) -> some View {
        Button {
            Haptics.selection()
            Task { await environment.startCatalogMix(mix) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HomeTrackArtwork(url: mix.artworkURL, size: artworkSize)
                Text(mix.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !mix.subtitle.isEmpty {
                    Text(mix.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, alignment: .leading)
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dynamic artist

    /// Only rendered when `ArtistAffinityPolicy` actually has evidence —
    /// weak or absent affinity means no section, not a filler card.
    private func dynamicArtistSection(
        _ candidate: ArtistAffinityCandidate,
        metrics: HomeMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            PremiumSectionHeader("selena.name")
            HStack(spacing: BubbleSpacing.m) {
                dynamicArtistGlyph(candidate, size: metrics.recentWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        L10n.format(
                            "home_stage.dynamic_artist.title",
                            candidate.displayName
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(dynamicArtistReasonText(candidate.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: BubbleSpacing.s) {
                        Button {
                            continueDynamicArtist(candidate)
                        } label: {
                            if isDynamicArtistLaunching {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(
                                    L10n.text(
                                        "home_stage.dynamic_artist.continue"
                                    )
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isDynamicArtistLaunching)

                        Button(role: .destructive) {
                            hideDynamicArtist(candidate)
                        } label: {
                            Text(L10n.text("hide_artist"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.secondary)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func dynamicArtistGlyph(
        _ candidate: ArtistAffinityCandidate,
        size: CGFloat
    ) -> some View {
        let tint = BubblePalette.surface(.artist, tint: nil).color
        return ZStack {
            LinearGradient(
                colors: [tint, tint.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size * 0.62, height: size * 0.62)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size * 0.62),
                style: .continuous
            )
        )
    }

    private func dynamicArtistReasonText(
        _ reason: ArtistAffinityCandidate.Reason
    ) -> String {
        switch reason {
        case .likedAndPlayed:
            L10n.text("home_stage.dynamic_artist.reason.liked")
        case .frequentRecently:
            L10n.text("home_stage.dynamic_artist.reason.frequent")
        case .multipleTracks:
            L10n.text("home_stage.dynamic_artist.reason.multiple")
        }
    }

    private func continueDynamicArtist(_ candidate: ArtistAffinityCandidate) {
        guard !isDynamicArtistLaunching else { return }
        Haptics.selection()
        let seed = seedTrack(forArtistKey: candidate.artistKey)
        isDynamicArtistLaunching = true
        Task {
            defer { isDynamicArtistLaunching = false }
            await environment.startMixFromArtist(
                named: candidate.displayName,
                seed: seed
            )
        }
    }

    /// Reuses `MixFeedbackStore` rather than a second suppression list —
    /// the same ban already keeps this artist out of Mix Radio, and now
    /// out of `ArtistAffinityPolicy`'s candidates too.
    private func hideDynamicArtist(_ candidate: ArtistAffinityCandidate) {
        Haptics.selection()
        guard let seed = seedTrack(forArtistKey: candidate.artistKey) else {
            return
        }
        mixFeedback.ban(seed, includeArtist: true)
        personalization.clearIfShowing(artistKey: candidate.artistKey)
    }

    private func recommendationsSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            PremiumSectionHeader(
                "for_you",
                subtitle: "recommendations_based_on_vk_data"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: metrics.cardSpacing
                ) {
                    ForEach(featuredRecommendations) { track in
                        homeTrackItem(
                            track,
                            queue: recommendations,
                            artworkSize: metrics.trackWidth
                        )
                        .contextMenu {
                            trackContextMenu(track, queue: recommendations)
                        }
                    }
                }
            }
        }
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
                    ForEach(history.entries.prefix(12)) { entry in
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

    private func catalogSkeleton(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
            ForEach(0..<2, id: \.self) { section in
                VStack(alignment: .leading, spacing: BubbleSpacing.m) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.11))
                        .frame(
                            width: section == 0 ? 112 : 150,
                            height: 16
                        )
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(
                            alignment: .top,
                            spacing: metrics.cardSpacing
                        ) {
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(
                                        cornerRadius:
                                            PremiumLayout.artworkRadius(
                                                for: metrics.trackWidth
                                            ),
                                        style: .continuous
                                    )
                                        .fill(.primary.opacity(0.09))
                                        .frame(
                                            width: metrics.trackWidth,
                                            height: metrics.trackWidth
                                        )
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.primary.opacity(0.09))
                                        .frame(
                                            width: metrics.trackWidth * 0.82,
                                            height: 11
                                        )
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.primary.opacity(0.06))
                                        .frame(
                                            width: metrics.trackWidth * 0.58,
                                            height: 9
                                        )
                                }
                                .frame(
                                    width: metrics.trackWidth,
                                    alignment: .leading
                                )
                            }
                        }
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel(L10n.text("loading_recommendations_and_mixes"))
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

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 40, weight: .medium))
            Text(L10n.text("home.unavailable"))
                .font(.title3.bold())
            Text(
                errorMessage
                    ?? L10n.text("vk_did_not_return_recommendations")
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.text("action.refresh")) { Task { await load(force: true) } }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
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

struct HomeMetrics {
    let containerWidth: CGFloat

    var horizontalPadding: CGFloat {
        AdaptiveLayout.horizontalPadding(for: containerWidth)
    }

    var cardSpacing: CGFloat {
        containerWidth <= 350 ? 10 : 12
    }

    var trackWidth: CGFloat {
        AdaptiveLayout.shelfCardWidth(
            for: containerWidth,
            compactMax: 142,
            regularMax: AdaptiveLayout.regularCardWidthCap,
            fraction: 0.36,
            compactMin: 114
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
