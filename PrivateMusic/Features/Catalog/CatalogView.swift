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
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionErrorMessage: String?
    @State private var sharingTrack: Track?
    @State private var selectedAlbum: Album?
    @State private var loadingAlbumTrackID: String?
    @State private var albumLookupTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { proxy in
                let metrics = HomeMetrics(containerWidth: proxy.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if settings.homeStageEnabled {
                            HomeStageView(
                                width: proxy.size.width,
                                horizontalPadding: metrics.horizontalPadding,
                                topSafeAreaInset: proxy.safeAreaInsets.top
                            )
                            .id(MainTabScrollDestination.home)
                        } else {
                            welcomeHeader
                                .padding(.top, proxy.safeAreaInsets.top)
                                .id(MainTabScrollDestination.home)
                        }

                        if !history.entries.isEmpty {
                            recentlyPlayedSection(metrics: metrics)
                        }
                        if isLoading && contentIsEmpty {
                            catalogSkeleton(metrics: metrics)
                        } else {
                            // One discovery section, full stop — station,
                            // mood and the VK mix catalog already have a
                            // home in the stage rail and the Mix tab.
                            // Duplicating them here is what made Home read
                            // as a second copy of the rest of the app.
                            if !recommendations.isEmpty {
                                recommendationsSection(metrics: metrics)
                            }
                            if contentIsEmpty { unavailableView }
                            if let errorMessage, !contentIsEmpty {
                                retryRow(errorMessage)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 4)
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

    /// Home's own discovery signal: the one section it still renders.
    /// Mixes, new releases and playlists moved to the Mix and Library
    /// tabs that already own them — their emptiness no longer belongs in
    /// this check.
    private var contentIsEmpty: Bool { recommendations.isEmpty }

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

    private func recommendationsSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
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
        VStack(alignment: .leading, spacing: 11) {
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
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<2, id: \.self) { section in
                VStack(alignment: .leading, spacing: 11) {
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
