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
    @State private var loadingPlayAlbumID: String?
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
                                horizontalPadding: metrics.horizontalPadding
                            )
                            .id(MainTabScrollDestination.home)
                        } else {
                            welcomeHeader
                                .id(MainTabScrollDestination.home)
                        }

                        if !history.entries.isEmpty {
                            recentlyPlayedSection(metrics: metrics)
                        }
                        if isLoading && contentIsEmpty {
                            catalogSkeleton(metrics: metrics)
                        } else {
                            if !homeCatalog.newReleases.isEmpty {
                                newReleasesSection(metrics: metrics)
                            }
                            vibeChipsSection
                            if !homeMixes.isEmpty {
                                mixesSection(metrics: metrics)
                            }
                            if !recommendations.isEmpty {
                                recommendationsSection(metrics: metrics)
                                if !moreRecommendations.isEmpty {
                                    trackListSection
                                }
                            }
                            if !playlists.isEmpty {
                                playlistsSection(metrics: metrics)
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
    private var moreRecommendations: [Track] {
        Array(recommendations.dropFirst(14).prefix(16))
    }
    private var playlists: [Playlist] { homeCatalog.playlists }
    private var isLoading: Bool { homeCatalog.isRefreshing }
    private var errorMessage: String? {
        actionErrorMessage ?? homeCatalog.errorMessage
    }

    private var contentIsEmpty: Bool {
        recommendations.isEmpty && playlists.isEmpty
            && homeCatalog.newReleases.isEmpty
            && homeCatalog.mixes.isEmpty
    }

    /// Home carries one mix shelf. The themed "charts" and "kids" shelves
    /// used to sit here too, but every mix they showed is also in this
    /// shelf and in the Mix tab, so the same card appeared two or three
    /// times across one screen — and Home grew to ten stacked sections.
    /// The Mix tab groups all of them (social, official shelves,
    /// algorithmic) so nothing is lost by keeping Home to a single row.
    private var homeMixes: [MusicMix] {
        Array(
            homeCatalog.mixes
                .filter { $0.id != MusicMix.common.id }
                .prefix(16)
        )
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

    private var vibeChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(
                L10n.text("what_is_the_vibe_right_now"),
                subtitle: L10n.text("a_quick_start_based_on_your_mood")
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MixMoodPreference.allCases.filter { $0 != .any }) {
                        mood in
                        Button {
                            settings.mixMoodPreference = mood
                            Task { await playVibe(mood) }
                        } label: {
                            Text(mood.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(
                            settings.mixMoodPreference == mood
                                ? settings.theme.accent
                                : Color.secondary
                        )
                    }
                }
            }
        }
    }

    private func mixesSection(metrics: HomeMetrics) -> some View {
        shelfMixesSection(
            title: L10n.text("mixes"),
            subtitle: L10n.text("selena.catalog_subtitle"),
            mixes: homeMixes,
            metrics: metrics
        )
    }

    private func shelfMixesSection(
        title: String,
        subtitle: String,
        mixes: [MusicMix],
        metrics: HomeMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(mixes) { mix in
                        Button {
                            Task {
                                await environment.startCatalogMix(mix)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                MixArtworkView(
                                    mix: mix,
                                    tracks: [],
                                    size: metrics.trackWidth
                                )
                                Text(mix.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(
                                        width: metrics.trackWidth,
                                        alignment: .leading
                                    )
                                if let percent = mix.matchPercent {
                                    Text(
                                        L10n.format("percent_d0", percent)
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                } else if let curator = mix.curator?.displayName {
                                    Text(curator)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            Button {
                                Task {
                                    await environment.startCatalogMix(mix)
                                }
                            } label: {
                                Label(L10n.text("listen"),
                                    systemImage: "play.fill"
                                )
                            }
                            if let curator = mix.curator, curator.isUsable {
                                Text(curator.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Resolution lives in `MixMoodLaunchPolicy` so the vibe chips here
    /// and the mood bubble on the stage cannot drift into two different
    /// answers for the same mood.
    private func playVibe(_ mood: MixMoodPreference) async {
        await environment.startMoodStation(mood, in: homeCatalog.mixes)
    }

    private func recommendationsSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(
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
            HomeSectionHeader(
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

    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(
                "more_for_you",
                subtitle: "more_recommendations"
            )
            VStack(spacing: 0) {
                ForEach(
                    Array(moreRecommendations.enumerated()),
                    id: \.element.id
                ) { index, track in
                    TrackRow(track: track, queue: recommendations)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    if index < moreRecommendations.count - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .premiumCard()
        }
    }

    private func newReleasesSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            NavigationLink {
                NewReleasesView(albums: homeCatalog.newReleases)
            } label: {
                HStack {
                    HomeSectionHeader(
                        "new_releases",
                        subtitle: "fresh_albums"
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: metrics.cardSpacing
                ) {
                    ForEach(homeCatalog.newReleases.prefix(16)) { album in
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                Button { selectedAlbum = album } label: {
                                    AsyncArtwork(
                                        url: album.artworkURL,
                                        size: metrics.newReleaseWidth
                                    )
                                }
                                .buttonStyle(PremiumPressStyle())

                                let playbackAction = playbackAction(for: album)
                                Button {
                                    performPlaybackAction(
                                        playbackAction,
                                        for: album
                                    )
                                } label: {
                                    Group {
                                        if loadingPlayAlbumID == album.id {
                                            ProgressView()
                                                .tint(.black)
                                        } else {
                                            Image(
                                                systemName:
                                                    playbackAction.systemImage
                                            )
                                        }
                                    }
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 30, height: 30)
                                    .background(.white, in: Circle())
                                }
                                .buttonStyle(PremiumPressStyle())
                                .padding(6)
                                .disabled(
                                    loadingPlayAlbumID != nil
                                        && loadingPlayAlbumID != album.id
                                )
                                .accessibilityLabel(
                                    L10n.text(
                                        playbackAction.accessibilityLabelKey(
                                            playKey: "play_album"
                                        )
                                    )
                                )
                            }
                            Button { selectedAlbum = album } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        Album.isUsableTitle(album.title)
                                            ? album.title
                                            : L10n.text("album")
                                    )
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                    Text(album.artistText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(
                            width: metrics.newReleaseWidth,
                            alignment: .topLeading
                        )
                    }
                }
            }
        }
    }

    private func playlistsSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(
                "your_playlists",
                subtitle: L10n.format(
                    "n_0_in_your_library",
                    L10n.playlistCount(playlists.count)
                )
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: metrics.cardSpacing
                ) {
                    ForEach(playlists.prefix(16)) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PlaylistArtworkView(
                                    playlist: playlist,
                                    size: metrics.playlistWidth
                                )
                                Text(playlist.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(
                                        height: 34,
                                        alignment: .topLeading
                                    )
                                Text(
                                    L10n.format(
                                        "n_0_1",
                                        L10n.trackCount(playlist.count),
                                        playlist.source.shortTitle
                                    )
                                )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(
                                width: metrics.playlistWidth,
                                alignment: .topLeading
                            )
                        }
                        .buttonStyle(PremiumPressStyle())
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

    private func playAlbum(_ album: Album) {
        guard sessionStore.accessToken != nil else { return }
        loadingPlayAlbumID = album.id
        Task {
            defer { loadingPlayAlbumID = nil }
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.albumTracks(
                        album,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
                guard let first = page.items.first else { return }
                environment.player.play(
                    first,
                    in: page.items,
                    source: albumQueueSource(for: album)
                )
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func playbackAction(for album: Album) -> QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: albumQueueSource(for: album),
            isPlaying: highlight.isPlaying,
            queueSource: highlight.queueSource
        )
    }

    private func performPlaybackAction(
        _ action: QueueSourcePlaybackAction,
        for album: Album
    ) {
        switch action {
        case .start:
            playAlbum(album)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func albumQueueSource(for album: Album) -> QueueSource {
        .album(title: albumPlaybackTitle(album))
    }

    private func albumPlaybackTitle(_ album: Album) -> String {
        Album.isUsableTitle(album.title) ? album.title : L10n.text("album")
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

    var playlistWidth: CGFloat {
        AdaptiveLayout.shelfCardWidth(
            for: containerWidth,
            compactMax: 140,
            regularMax: AdaptiveLayout.regularCardWidthCap,
            fraction: 0.35,
            compactMin: 112
        )
    }

    var newReleaseWidth: CGFloat {
        AdaptiveLayout.shelfCardWidth(
            for: containerWidth,
            compactMax: 140,
            regularMax: AdaptiveLayout.regularCardWidthCap,
            fraction: 0.35,
            compactMin: 112
        )
    }
}

private struct HomeSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.headline.weight(.bold))
                .lineLimit(1)
            if let subtitle {
                Text(L10n.text(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
