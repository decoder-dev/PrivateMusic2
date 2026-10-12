import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(AudioPlayer.self) private var player
    let album: Album
    @State private var model = AlbumDetailViewModel()
    @State private var resolvedAlbum: Album?
    @State private var isUpdatingFollow = false
    @State private var actionErrorMessage: String?
    @State private var showsNavTitle = false

    /// A caller that already loaded the complete album can avoid an empty loading frame.
    init(album: Album, loadedTracks: [Track]? = nil) {
        self.album = album
        _model = State(initialValue: AlbumDetailViewModel(loadedTracks: loadedTracks))
    }

    var body: some View {
        Group {
            if model.tracks.isEmpty && (!model.hasLoaded || model.isLoading) {
                ProgressView(L10n.text("loading_album"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasLoaded && model.tracks.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        title: model.errorMessage == nil
                            ? "album_has_no_available_tracks"
                            : "could_not_open_album",
                        systemImage: model.errorMessage == nil
                            ? "music.note.list"
                            : "lock.fill",
                        description: model.errorMessage
                            ?? "vk_returned_no_available_audio",
                        descriptionIsLocalizedKey: model.errorMessage == nil
                    )
                    Button(L10n.text("action.retry")) {
                        Task { await load(force: true) }
                    }
                    .buttonStyle(PremiumProminentButtonStyle())
                    .padding(.bottom, 32)
                }
            } else {
                albumList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
        .clearsMiniPlayer(includingWhenDockReservesSpace: true)
        .collapsingInlineNavigationTitle(
            displayedTitle,
            isVisible: $showsNavTitle
        )
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .alert(
            "could_not_update_album",
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

    private var albumList: some View {
        List {
            Section {
                albumHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: PremiumLayout.screenPadding,
                                             bottom: 6, trailing: PremiumLayout.screenPadding))
                    .listRowSeparator(.hidden)
            }
            ForEach(model.tracks) { track in
                TrackRow(
                    track: track,
                    queue: model.tracks,
                    source: .album(title: displayedTitle)
                )
                .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: PremiumLayout.screenPadding,
                                             bottom: 6, trailing: PremiumLayout.screenPadding))
                .onAppear {
                    if track.id == model.tracks.last?.id {
                        Task { await loadMore() }
                    }
                }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView(L10n.text("loading_more"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: PremiumLayout.screenPadding,
                                             bottom: 6, trailing: PremiumLayout.screenPadding))
            } else if let error = model.paginationErrorMessage {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: PremiumLayout.screenPadding,
                                             bottom: 6, trailing: PremiumLayout.screenPadding))
                .listRowSeparator(.hidden)
            } else if let error = model.errorMessage,
                      !model.tracks.isEmpty {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: PremiumLayout.screenPadding,
                                             bottom: 6, trailing: PremiumLayout.screenPadding))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }

    private var albumHeader: some View {
        VStack(spacing: 14) {
            AsyncArtwork(url: displayedAlbum.artworkURL, size: 190)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            VStack(spacing: 5) {
                Text(displayedTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .heroTitleScrollAnchor()
                if !displayedAlbum.artists.isEmpty {
                    Text(displayedAlbum.artistText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let releaseDate = displayedAlbum.releaseDate {
                    Text(releaseDate.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let releaseYear = displayedAlbum.releaseYear {
                    Text(String(releaseYear))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if displayedTrackCount > 0 {
                    Text(L10n.trackCount(displayedTrackCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            headerActions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var headerActions: some View {
        if dynamicTypeSize.isAccessibilitySize || ContrastPolicy.flattensCustomGlass(
            reduceTransparency: reduceTransparency, increaseContrast: colorSchemeContrast == .increased,
            prefersClassicChrome: settings.classicChrome
        ) {
            verticalHeaderActions
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    listenButton.frame(minWidth: 152)
                    secondaryHeaderActions
                }
                verticalHeaderActions
            }
        }
    }

    private var verticalHeaderActions: some View {
        VStack(spacing: 12) {
            listenButton
            secondaryHeaderActions
        }
    }

    private var secondaryHeaderActions: some View {
        HStack(spacing: 12) {
                shuffleButton
                Button(action: toggleFollow) {
                    Image(systemName: isFollowed ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(
                            isFollowed
                                ? settings.accent
                                : settings.accent
                        )
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                        .adaptiveGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.borderless)
                .disabled(isUpdatingFollow)
                .accessibilityLabel(
                    L10n.text(
                        isFollowed
                            ? "remove_album_from_library"
                            : "add_album_to_library"
                    )
                )
                .accessibilityAddTraits(isFollowed ? .isSelected : [])
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(settings.accent)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .adaptiveGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text("share_album"))
                }
            }
    }

    /// Keep the playback icon and title together as the available width changes.
    private var listenButtonLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: listenAction.systemImage).accessibilityHidden(true)
            Text(L10n.text(listenAction == .pause ? "pause_2" : "listen"))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var listenButton: some View {
        if #available(iOS 26.0, *), !ContrastPolicy.flattensCustomGlass(
            reduceTransparency: reduceTransparency, increaseContrast: colorSchemeContrast == .increased,
            prefersClassicChrome: settings.classicChrome
        ) {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(.glassProminent)
            .tint(settings.accent)
            .disabled(model.tracks.isEmpty)
        } else {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(PremiumProminentButtonStyle())
            .tint(settings.accent)
            .disabled(model.tracks.isEmpty)
        }
    }

    private var shuffleButton: some View {
        Button(action: shuffleAlbum) {
            Image(systemName: "shuffle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(settings.accent)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.borderless)
        .disabled(model.tracks.isEmpty)
        .accessibilityLabel(L10n.text("shuffle"))
    }

    private var isFollowed: Bool {
        likedAlbumsStore.isFollowed(displayedAlbum)
    }

    private var shareURL: URL? {
        AlbumShareLinkBuilder.url(for: displayedAlbum)
    }

    private var displayedTrackCount: Int {
        displayedAlbum.count
    }

    private var displayedAlbum: Album {
        (resolvedAlbum ?? album).normalized(using: model.tracks)
    }

    private var displayedTitle: String {
        Album.isUsableTitle(displayedAlbum.title)
            ? displayedAlbum.title
            : L10n.text("album")
    }

    private var currentSource: QueueSource {
        .album(title: displayedTitle)
    }

    private var listenAction: QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: currentSource,
            isPlaying: player.isPlaying,
            queueSource: player.queueSource
        )
    }

    private func toggleListen() {
        switch listenAction {
        case .start:
            playAlbum()
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func playAlbum() {
        guard let first = model.tracks.first else { return }
        environment.player.play(
            first,
            in: model.tracks,
            source: currentSource
        )
    }

    private func shuffleAlbum() {
        environment.player.playShuffled(
            in: model.tracks,
            source: .album(title: displayedTitle)
        )
    }

    private func toggleFollow() {
        guard !isUpdatingFollow else { return }
        let album = displayedAlbum
        let desired = !likedAlbumsStore.isFollowed(album)
        isUpdatingFollow = true
        // Optimistic local update so the heart reacts immediately; revert
        // if VK rejects the followPlaylist toggle.
        if desired {
            likedAlbumsStore.markFollowed(album)
        } else {
            likedAlbumsStore.markUnfollowed(album)
        }
        Task {
            defer { isUpdatingFollow = false }
            do {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.toggleAlbumFollow(
                        album,
                        follow: desired,
                        accessToken: token
                    )
                }
                NotificationCenter.default.post(
                    name: .likedAlbumsDidChange,
                    object: nil
                )
                Haptics.success()
            } catch {
                if desired {
                    likedAlbumsStore.markUnfollowed(album)
                } else {
                    likedAlbumsStore.markFollowed(album)
                }
                actionErrorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func load(force: Bool) async {
        guard sessionStore.accessToken != nil else { return }
        await model.load(force: force) {
            try await environment.withAuthorizedToken { token in
                let enriched = try await environment.musicService.resolvedAlbum(
                    album,
                    accessToken: token
                )
                resolvedAlbum = enriched
                return try await environment.musicService.albumTracks(
                    enriched,
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
    }

    private func loadMore() async {
        let active = resolvedAlbum ?? album
        await model.loadMore { offset in
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.albumTracks(
                    active,
                    accessToken: token,
                    offset: offset,
                    count: 100
                )
            }
        }
    }
}

@MainActor
@Observable
private final class AlbumDetailViewModel {
    private(set) var tracks: [Track] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    var errorMessage: String?
    var paginationErrorMessage: String?
    private var nextOffset: Int?

    init(loadedTracks: [Track]? = nil) {
        var seen = Set<String>()
        tracks = (loadedTracks ?? []).filter { seen.insert($0.id).inserted }
        hasLoaded = loadedTracks != nil
    }

    func load(
        force: Bool,
        operation: () async throws -> MusicPage<Track>
    ) async {
        guard !isLoading,
              !isLoadingMore,
              force || tracks.isEmpty else { return }
        isLoading = true
        paginationErrorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await operation()
            tracks = page.items
            nextOffset = page.nextOffset
            errorMessage = nil
            paginationErrorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Track>
    ) async {
        guard !isLoading, !isLoadingMore, let offset = nextOffset else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await operation(offset)
            var known = Set(tracks.map(\.id))
            tracks.append(contentsOf: page.items.filter {
                known.insert($0.id).inserted
            })
            nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            paginationErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            paginationErrorMessage = error.localizedDescription
        }
    }
}
