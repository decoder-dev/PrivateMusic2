import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: ListeningHistoryStore
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @State private var loadingMixID: String?
    @State private var actionErrorMessage: String?
    @State private var sharingTrack: Track?

    var body: some View {
        GeometryReader { proxy in
            let metrics = HomeMetrics(containerWidth: proxy.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    welcomeHeader

                    if !history.entries.isEmpty {
                        recentlyPlayedSection(metrics: metrics)
                    }
                    if isLoading && contentIsEmpty {
                        catalogSkeleton(metrics: metrics)
                    } else {
                        if !mixes.isEmpty {
                            mixesSection(metrics: metrics)
                        }
                        if !recommendations.isEmpty {
                            recommendationsSection(metrics: metrics)
                            trackListSection
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
        .background(ThemeBackground())
        .navigationTitle("Главная")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .trackShareSheet(track: $sharingTrack)
        .refreshable { await load(force: true) }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            await load()
        }
    }

    private var recommendations: [Track] { homeCatalog.recommendations }
    private var mixes: [MusicMix] { homeCatalog.mixes }
    private var playlists: [Playlist] { homeCatalog.playlists }
    private var isLoading: Bool { homeCatalog.isRefreshing }
    private var errorMessage: String? {
        actionErrorMessage ?? homeCatalog.errorMessage
    }

    private var contentIsEmpty: Bool {
        recommendations.isEmpty && mixes.isEmpty && playlists.isEmpty
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

    private func mixesSection(metrics: HomeMetrics) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader(
                "Миксы VK",
                subtitle: "Персональный поток под ваш вкус"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.cardSpacing) {
                    ForEach(mixes) { mix in
                        Button { start(mix) } label: {
                            ZStack(alignment: .bottomLeading) {
                                MixArtworkView(
                                    mix: mix,
                                    tracks: recommendations,
                                    size: metrics.mixWidth,
                                    height: metrics.mixHeight,
                                    cornerRadius: 12
                                )
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        .black.opacity(0.18),
                                        .black.opacity(0.78)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                HStack(alignment: .bottom, spacing: 8) {
                                    Text(mix.title)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "play.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 30, height: 30)
                                        .foregroundStyle(.black)
                                        .background(.white, in: Circle())
                                }
                                .padding(10)
                                if loadingMixID == mix.id {
                                    ProgressView()
                                        .tint(.white)
                                        .frame(
                                            maxWidth: .infinity,
                                            maxHeight: .infinity
                                        )
                                        .background(.black.opacity(0.26))
                                }
                            }
                            .frame(
                                width: metrics.mixWidth,
                                height: metrics.mixHeight
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 12,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: 12,
                                    style: .continuous
                                )
                                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            Button { start(mix) } label: {
                                Label("Воспроизвести микс", systemImage: "play.fill")
                            }
                        }
                        .disabled(loadingMixID != nil)
                    }
                }
            }
        }
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
                    ForEach(recommendations.prefix(14)) { track in
                        Button {
                            player.play(track, in: recommendations)
                        } label: {
                            homeTrackCard(
                                track,
                                artworkSize: metrics.trackWidth,
                                showsPlayButton: true
                            )
                        }
                        .buttonStyle(PremiumPressStyle())
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
                        Button {
                            let tracks = history.entries.map(\.track)
                            player.play(entry.track, in: tracks)
                        } label: {
                            homeTrackCard(
                                entry.track,
                                artworkSize: metrics.recentWidth
                            )
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            trackContextMenu(
                                entry.track,
                                queue: history.entries.map(\.track)
                            )
                        }
                    }
                }
            }
        }
    }

    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HomeSectionHeader("Ещё для вас")
            VStack(spacing: 0) {
                ForEach(Array(recommendations.prefix(10).enumerated()), id: \.element.id) {
                    index, track in
                    TrackRow(track: track, queue: recommendations)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    if index < min(recommendations.count, 10) - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .premiumCard()
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
        artworkSize: CGFloat,
        showsPlayButton: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                HomeTrackArtwork(
                    url: track.artworkURL,
                    size: artworkSize
                )
                if showsPlayButton {
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
                        .frame(width: 30, height: 30)
                        .background(settings.theme.accent, in: Circle())
                        .padding(7)
                }
            }
            Text(track.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(
                    player.currentTrack?.id == track.id
                        ? settings.theme.accent
                        : Color.primary
                )
                .lineLimit(2)
                .frame(height: 34, alignment: .topLeading)
            Text(track.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 15, alignment: .topLeading)
        }
        .frame(width: artworkSize, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trackContextMenu(
        _ track: Track,
        queue: [Track]
    ) -> some View {
        Button {
            player.playNext(track)
        } label: {
            Label("Играть следующим", systemImage: "text.badge.plus")
        }
        Button {
            player.play(track, in: queue)
            player.presentPlayer()
        } label: {
            Label("Открыть плеер", systemImage: "play.circle")
        }
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
                    ?? L10n.text("VK не вернул рекомендации и миксы.")
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

    private func start(_ mix: MusicMix) {
        guard sessionStore.accessToken != nil else { return }
        loadingMixID = mix.id
        Task {
            defer { loadingMixID = nil }
            do {
                let tracks = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracks(
                        mix,
                        accessToken: token
                    )
                }
                guard let first = tracks.first else { return }
                player.play(first, in: tracks) {
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.mixTracks(
                            mix,
                            accessToken: token
                        )
                    }
                }
                actionErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = L10n.format(
                    "Не удалось запустить «%@»: %@",
                    mix.title,
                    error.localizedDescription
                )
            }
        }
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

    var mixWidth: CGFloat {
        min(max(containerWidth * 0.52, 158), 184)
    }

    var mixHeight: CGFloat {
        mixWidth * 0.72
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
