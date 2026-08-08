import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: ListeningHistoryStore
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
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
                        welcomeHeader
                            .id(MainTabScrollDestination.home)

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
                            if !chartMixes.isEmpty {
                                shelfMixesSection(
                                    title: L10n.text("Чарты и хиты"),
                                    subtitle: L10n.text(
                                        "Полки каталога VK"
                                    ),
                                    mixes: chartMixes,
                                    metrics: metrics
                                )
                            }
                            if !kidsMixes.isEmpty {
                                shelfMixesSection(
                                    title: L10n.text("Детям"),
                                    subtitle: L10n.text(
                                        "Сказки, колыбельные и семейные миксы"
                                    ),
                                    mixes: kidsMixes,
                                    metrics: metrics
                                )
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
            }
            .onReceive(scrollCoordinator.$request) { request in
                guard request?.destination == .home else { return }
                scrollToTop(scrollProxy, destination: .home)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Главная")
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
        .onReceive(
            NotificationCenter.default.publisher(for: .likedAlbumsDidChange)
        ) { _ in
            Task { await load(force: true) }
        }
        .onReceive(environment.$mixActionError) { error in
            guard let error else { return }
            actionErrorMessage = error
            environment.mixActionError = nil
        }
        .alert(
            "Не удалось открыть альбом",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
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

    private var homeMixes: [MusicMix] {
        Array(
            homeCatalog.mixes
                .filter { $0.id != MusicMix.common.id }
                .prefix(16)
        )
    }

    private var kidsMixes: [MusicMix] {
        homeCatalog.mixes.filter {
            MixSeedRadio.looksLikeKidsShelf($0.sectionTitle ?? $0.title)
                || MixSeedRadio.looksLikeKidsShelf($0.subtitle)
        }
    }

    private var chartMixes: [MusicMix] {
        homeCatalog.mixes.filter {
            MixSeedRadio.looksLikeChartShelf($0.sectionTitle ?? $0.title)
        }
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
                        ?? L10n.text("Слушатель")
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
        case 5..<12: L10n.text("Доброе утро")
        case 12..<18: L10n.text("Добрый день")
        case 18..<23: L10n.text("Добрый вечер")
        default: L10n.text("Доброй ночи")
        }
    }

    private var vibeChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeSectionHeader(
                L10n.text("Какой сейчас вайб"),
                subtitle: L10n.text("Быстрый старт по настроению")
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
            title: L10n.text("Миксы"),
            subtitle: L10n.text("Селена, социальные и алгоритмические подборки"),
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
                                    .frame(
                                        width: metrics.trackWidth,
                                        alignment: .leading
                                    )
                                if let percent = mix.matchPercent {
                                    Text(
                                        L10n.format("%d%%", percent)
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
                                Label(
                                    "Слушать",
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

    private func playVibe(_ mood: MixMoodPreference) async {
        let matches = homeCatalog.mixes.filter {
            MixQueueFilter.shelfMatchesMood(
                $0.sectionTitle ?? $0.title,
                mood: mood
            )
                || MixQueueFilter.shelfMatchesMood($0.subtitle, mood: mood)
                || MixSeedRadio.looksLikeVibeShelf($0.sectionTitle ?? $0.title)
        }
        if let mix = matches.first {
            await environment.startCatalogMix(mix)
            return
        }
        if let personal = homeCatalog.mixes.first(
            where: { $0.id == MusicMix.common.id }
        ) {
            await environment.startCatalogMix(personal)
            return
        }
        await environment.startMixFromMyMusic()
    }

    private func recommendationsSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(
                "Для вас",
                subtitle: "Рекомендации на основе прослушиваний VK"
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
                "Недавно слушали",
                subtitle: "История сохраняется только на этом устройстве"
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
                "Ещё для вас",
                subtitle: "Продолжение рекомендаций"
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
                        "Новые релизы",
                        subtitle: "Свежие альбомы"
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

                                Button { playAlbum(album) } label: {
                                    Group {
                                        if loadingPlayAlbumID == album.id {
                                            ProgressView()
                                                .tint(.black)
                                        } else {
                                            Image(systemName: "play.fill")
                                        }
                                    }
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 30, height: 30)
                                    .background(.white, in: Circle())
                                }
                                .buttonStyle(PremiumPressStyle())
                                .padding(6)
                                .disabled(loadingPlayAlbumID != nil)
                                .accessibilityLabel(L10n.text("Воспроизвести альбом"))
                            }
                            Button { selectedAlbum = album } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        Album.isUsableTitle(album.title)
                                            ? album.title
                                            : L10n.text("Альбом")
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
                "Ваши плейлисты",
                subtitle: L10n.format(
                    "%@ в медиатеке",
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
                                    .frame(
                                        height: 34,
                                        alignment: .topLeading
                                    )
                                Text(
                                    L10n.format(
                                        "%@ • %@",
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
        .accessibilityLabel("Загружаем рекомендации и миксы")
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
                    player.currentTrack?.id == track.id
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
                player.play(track, in: queue, source: source)
            } label: {
                Group {
                    if player.currentTrack?.id == track.id {
                        PlaybackIndicatorView(
                            isPlaying: player.isPlaying,
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
            .accessibilityLabel(L10n.text("Воспроизвести трек"))
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
                "VK не вернул данные альбома для этого трека."
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
                    "Не удалось открыть альбом: %@",
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
                let title = Album.isUsableTitle(album.title)
                    ? album.title
                    : L10n.text("Альбом")
                player.play(
                    first,
                    in: page.items,
                    source: .album(title: title)
                )
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = error.localizedDescription
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
            player.playNext(track)
        } label: {
            Label("Играть следующим", systemImage: "text.badge.plus")
        }
        Button {
            player.play(track, in: queue, source: source)
            player.presentPlayer()
        } label: {
            Label("Открыть плеер", systemImage: "play.circle")
        }
        TrackMixActions.menuButtons(
            for: track,
            environment: environment
        )
        Button {
            sharingTrack = track
        } label: {
            Label("Поделиться аудиофайлом", systemImage: "square.and.arrow.up")
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 40, weight: .medium))
            Text("Музыка пока недоступна")
                .font(.title3.bold())
            Text(
                errorMessage
                    ?? L10n.text("VK не вернул рекомендации.")
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Обновить") { Task { await load(force: true) } }
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

private struct HomeMetrics {
    let containerWidth: CGFloat

    var horizontalPadding: CGFloat {
        containerWidth <= 350 ? 14 : 16
    }

    var cardSpacing: CGFloat {
        containerWidth <= 350 ? 10 : 12
    }

    var trackWidth: CGFloat {
        min(max(containerWidth * 0.36, 114), 142)
    }

    var recentWidth: CGFloat {
        min(max(containerWidth * 0.33, 108), 126)
    }

    var playlistWidth: CGFloat {
        min(max(containerWidth * 0.35, 112), 140)
    }

    var newReleaseWidth: CGFloat {
        min(max(containerWidth * 0.35, 112), 140)
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
    @EnvironmentObject private var settings: AppSettings
    let url: URL?
    let size: CGFloat

    var body: some View {
        CachedRemoteImage(url: url) { image in
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
