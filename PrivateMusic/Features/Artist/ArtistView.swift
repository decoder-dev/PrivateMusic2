import SwiftUI

struct ArtistView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var albumCaptionHeight: CGFloat = 60
    @State private var containerWidth: CGFloat = 390
    let artist: String
    let isPresentedModally: Bool
    private let isDesignPreview: Bool
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var resolvedArtist: VKArtist?
    @State private var isLoading = true
    @State private var isLoadingAlbums = false
    @State private var albumLoadError: String?
    @State private var loadingAlbumID: String?
    @State private var albumPlaybackTask: Task<Void, Never>?
    @State private var retryTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var selectedAlbum: Album?
    @State private var showsAllTracks = false
    @State private var pendingAlbumIDs = Set<String>()
    @State private var albumActionErrorMessage: String?
    @State private var albumActionErrorTitle = "could_not_play_album"
    /// Where the next page of tracks starts, or `nil` once VK has no more.
    /// The first load used to throw this away, which is why the artist page
    /// stopped dead at its first 50 tracks.
    @State private var nextTracksOffset: Int?
    @State private var isLoadingMoreTracks = false
    @State private var loadMoreTracksTask: Task<Void, Never>?

    init(artist: String, isPresentedModally: Bool = false,
         loadedTracks: [Track]? = nil, loadedAlbums: [Album] = [], loadedArtist: VKArtist? = nil) {
        self.artist = artist
        self.isPresentedModally = isPresentedModally
        isDesignPreview = loadedTracks != nil
        _tracks = State(initialValue: loadedTracks ?? [])
        _albums = State(initialValue: loadedAlbums)
        _resolvedArtist = State(initialValue: loadedArtist)
        _isLoading = State(initialValue: loadedTracks == nil)
    }

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty && albums.isEmpty {
                ArtistLoadingView(artist: artist)
            } else if tracks.isEmpty && albums.isEmpty && !isLoadingAlbums && albumLoadError == nil {
                emptyContent
            } else {
                trackContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
            if width > 0, abs(width - containerWidth) >= 1 { containerWidth = width }
        }
        .clearsMiniPlayer(includingWhenDockReservesSpace: true)
        .navigationTitle(L10n.text("artist"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if isPresentedModally {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("action.close"), systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedAlbum) { album in
            NavigationStack { AlbumDetailView(album: album) }
        }
        .alert(
            L10n.text(albumActionErrorTitle),
            isPresented: Binding(
                get: { albumActionErrorMessage != nil },
                set: { if !$0 { albumActionErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(albumActionErrorMessage ?? "")
        }
        .onDisappear {
            loadMoreTracksTask?.cancel()
            albumPlaybackTask?.cancel()
            retryTask?.cancel()
        }
        .task(id: artist) {
            guard !isDesignPreview else { return }
            resolvedArtist = nil
            // Tracks first so album cards can inherit count/artwork from the
            // same screen instead of painting sparse «0 треков» stubs.
            await load(resetContent: true)
            guard !Task.isCancelled else { return }
            await loadAlbums()
        }
    }

    private var trackContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                artistHeader

                if let errorMessage {
                    ArtistInlineError(
                        message: errorMessage,
                        retry: { retryArtist() }
                    )
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, 10)
                }

                if !tracks.isEmpty {
                    tracksSection
                        .padding(.top, BubbleSpacing.section)
                }

                if !albums.isEmpty || isLoadingAlbums || albumLoadError != nil {
                    albumsSection
                        .padding(.top, BubbleSpacing.section)
                }
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            guard retryTask == nil else { return }
            await load(resetContent: false)
            guard !Task.isCancelled else { return }
            await loadAlbums()
        }
        .sheet(isPresented: $showsAllTracks) {
            NavigationStack {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) {
                        index, track in
                        TrackRow(
                            track: track,
                            queue: tracks,
                            source: artistQueueSource,
                            allowsContinuation: false
                        )
                        .listRowBackground(Color.clear)
                        .onAppear {
                            guard ArtistTrackPagePolicy.shouldLoadMore(
                                visibleIndex: index,
                                loadedCount: tracks.count,
                                hasMore: nextTracksOffset != nil,
                                isLoading: isLoadingMoreTracks
                            ) else {
                                return
                            }
                            loadMoreTracks()
                        }
                    }
                    if isLoadingMoreTracks {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(L10n.text("loading_more"))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ThemeBackground())
                .navigationTitle(artist)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("done")) {
                            showsAllTracks = false
                        }
                    }
                }
            }
        }
    }

    private static let trackPreviewLimit = 6

    private var previewTracks: [Track] {
        Array(tracks.prefix(Self.trackPreviewLimit))
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.s) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: BubbleSpacing.s))
                : AnyLayout(HStackLayout(alignment: .center, spacing: BubbleSpacing.m))
            headerLayout {
                VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                    Text(L10n.text("artist_tracks"))
                        .font(BubbleType.section)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(nextTracksOffset == nil ? L10n.trackCount(tracks.count)
                         : L10n.format("artist.tracks.loaded", L10n.trackCount(tracks.count)))
                        .font(BubbleType.metadata).foregroundStyle(.secondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if tracks.count > Self.trackPreviewLimit || nextTracksOffset != nil {
                    Button { showsAllTracks = true } label: {
                        Label(L10n.text("see_all"), systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: PremiumLayout.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.accent)
                }
            }
            ForEach(previewTracks) { track in
                TrackRow(track: track, queue: tracks, source: artistQueueSource, allowsContinuation: false)
                    .padding(.vertical, BubbleSpacing.xs)
            }
        }
        .padding(.horizontal, PremiumLayout.screenPadding)
    }

    private var albumCardWidth: CGFloat {
        LibraryShelfMetrics.artworkSize(for: containerWidth)
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: LibraryShelfMetrics.headerSpacing) {
            Text(L10n.text("library.albums"))
                .font(BubbleType.section)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, PremiumLayout.screenPadding)
            if isLoadingAlbums && albums.isEmpty {
                LoadingShelf(width: containerWidth, captionHeight: albumCaptionHeight)
                    .padding(.horizontal, PremiumLayout.screenPadding)
            } else if !albums.isEmpty, dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: BubbleSpacing.m) {
                    ForEach(albums) { album in artistAlbumListRow(album) }
                }
                .padding(.horizontal, PremiumLayout.screenPadding)
            } else if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: LibraryShelfMetrics.cardSpacing) {
                        ForEach(albums) { album in artistAlbumCard(album) }
                    }
                    .padding(.horizontal, PremiumLayout.screenPadding)
                }
                .frame(height: albumCardWidth + LibraryShelfMetrics.captionSpacing + albumCaptionHeight)
            }
            if let albumLoadError {
                ArtistInlineError(message: albumLoadError, retry: { retryArtist(albumsOnly: true) })
                    .padding(.horizontal, PremiumLayout.screenPadding)
            }
        }
        .padding(.bottom, BubbleSpacing.l)
    }

    private func artistAlbumCard(_ album: Album) -> some View {
        Button {
            Haptics.selection()
            selectedAlbum = album
        } label: {
            VStack(alignment: .leading, spacing: LibraryShelfMetrics.captionSpacing) {
                AsyncArtwork(url: album.artworkURL, size: albumCardWidth)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        Album.isUsableTitle(album.title)
                            ? album.title
                            : L10n.text("album")
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.trackCount(album.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Keep spare space below the whole caption, never between its labels.
                .frame(height: albumCaptionHeight, alignment: .topLeading)
            }
            .frame(width: albumCardWidth,
                   height: albumCardWidth + LibraryShelfMetrics.captionSpacing + albumCaptionHeight,
                   alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if loadingAlbumID == album.compositeID {
                    ProgressView().padding(BubbleSpacing.s)
                        .background(settings.surfaceColor, in: Circle())
                        .padding(BubbleSpacing.s)
                }
            }
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu { artistAlbumMenu(album) }
    }

    private func artistAlbumListRow(_ album: Album) -> some View {
        Button { selectedAlbum = album } label: {
            HStack(spacing: BubbleSpacing.m) {
                AsyncArtwork(url: album.artworkURL, size: 56)
                VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                    Text(artistAlbumPlaybackTitle(album))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.trackCount(album.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu { artistAlbumMenu(album) }
    }

    @ViewBuilder
    private func artistAlbumMenu(_ album: Album) -> some View {
        let playbackAction = artistAlbumPlaybackAction(for: album)
            Button {
                performArtistAlbumPlaybackAction(
                    artistAlbumPlaybackAction(for: album),
                    for: album
                )
            } label: {
                Label(
                    L10n.text(playbackAction == .pause ? "pause" : "listen"),
                    systemImage: playbackAction.systemImage
                )
            }
            .disabled(loadingAlbumID != nil)
            Button {
                toggleArtistAlbumFollow(album)
            } label: {
                Label(
                    likedAlbumsStore.isFollowed(album)
                        ? "remove_album_from_library"
                        : "add_album_to_library",
                    systemImage: likedAlbumsStore.isFollowed(album)
                        ? "heart.slash"
                        : "heart"
                )
            }
            .disabled(pendingAlbumIDs.contains(album.compositeID))
            if let url = AlbumShareLinkBuilder.url(for: album) {
                ShareLink(item: url) {
                    Label(L10n.text("share_link"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
    }

    private func artistAlbumPlaybackTitle(_ album: Album) -> String {
        Album.isUsableTitle(album.title) ? album.title : L10n.text("album")
    }

    private func artistAlbumQueueSource(for album: Album) -> QueueSource {
        .album(title: artistAlbumPlaybackTitle(album))
    }

    private func artistAlbumPlaybackAction(
        for album: Album
    ) -> QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: artistAlbumQueueSource(for: album),
            isPlaying: highlight.isPlaying,
            queueSource: highlight.queueSource
        )
    }

    private func performArtistAlbumPlaybackAction(
        _ action: QueueSourcePlaybackAction,
        for album: Album
    ) {
        switch action {
        case .start:
            playArtistAlbum(album)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func playArtistAlbum(_ album: Album) {
        guard sessionStore.accessToken != nil, albumPlaybackTask == nil else { return }
        loadingAlbumID = album.compositeID
        albumPlaybackTask = Task {
            defer {
                loadingAlbumID = nil
                albumPlaybackTask = nil
            }
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.albumTracks(
                        album,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
                try Task.checkCancellation()
                guard let first = page.items.first else {
                    albumActionErrorTitle = "could_not_play_album"
                    albumActionErrorMessage = L10n.text("could_not_load_this_album_s_tracks_try_again_or_find_it_in_search")
                    return
                }
                environment.player.play(
                    first,
                    in: page.items,
                    source: artistAlbumQueueSource(for: album)
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                albumActionErrorTitle = "could_not_play_album"
                albumActionErrorMessage = error.localizedDescription
            }
        }
    }

    private func toggleArtistAlbumFollow(_ album: Album) {
        guard pendingAlbumIDs.insert(album.compositeID).inserted else {
            return
        }
        let desired = !likedAlbumsStore.isFollowed(album)
        Task {
            defer { pendingAlbumIDs.remove(album.compositeID) }
            do {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.toggleAlbumFollow(
                        album,
                        follow: desired,
                        accessToken: token
                    )
                }
                if desired {
                    likedAlbumsStore.markFollowed(album)
                } else {
                    likedAlbumsStore.markUnfollowed(album)
                }
                NotificationCenter.default.post(
                    name: .likedAlbumsDidChange,
                    object: nil
                )
                Haptics.success()
            } catch {
                albumActionErrorTitle = "could_not_update_album"
                albumActionErrorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private var artistQueueSource: QueueSource {
        .artist(name: artist)
    }

    private var artistPlaybackAction: QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(target: artistQueueSource, isPlaying: highlight.isPlaying,
                                         queueSource: highlight.queueSource)
    }

    private func playArtistTracks() {
        switch artistPlaybackAction {
        case .start:
            guard let first = tracks.first else { return }
            environment.player.play(first, in: tracks, source: artistQueueSource, allowsContinuation: false)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private var artistHeader: some View {
        ArtistHeaderCard(name: artist, photoURL: ArtistArtworkPolicy.portraitURL(for: resolvedArtist),
                         subtitle: L10n.text(resolvedArtist == nil ? "artist" : "vk_artist"),
                         playbackAction: tracks.isEmpty ? nil : artistPlaybackAction,
                         onPlay: playArtistTracks,
                         onShuffle: {
                             environment.player.playShuffled(in: tracks, source: artistQueueSource, allowsContinuation: false)
                         })
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.top, BubbleSpacing.m)
    }

    private var emptyContent: some View {
        ScrollView {
            VStack(spacing: BubbleSpacing.section) {
                artistHeader
                ArtistMessageView(
                    title: L10n.text("artist_unavailable"),
                    description: errorMessage
                        ?? L10n.text("vk_did_not_return_any_available_tracks_for_this_artist"),
                    systemImage: errorMessage == nil ? "music.note.list" : "exclamationmark.circle",
                    retry: sessionStore.accessToken == nil ? nil : { retryArtist() }
                )
                .frame(minHeight: 240)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func retryArtist(albumsOnly: Bool = false) {
        guard retryTask == nil else { return }
        retryTask = Task {
            defer { retryTask = nil }
            if !albumsOnly { await load(resetContent: tracks.isEmpty) }
            guard !Task.isCancelled else { return }
            await loadAlbums()
        }
    }

    @MainActor
    private func load(resetContent: Bool) async {
        let requestedArtist = artist
        // A reload replaces the whole list, so any page in flight is about
        // to append rows that no longer belong to it.
        loadMoreTracksTask?.cancel()
        loadMoreTracksTask = nil
        isLoadingMoreTracks = false
        nextTracksOffset = nil
        if resetContent {
            tracks = []
        }
        errorMessage = nil

        guard sessionStore.accessToken != nil else {
            isLoading = false
            errorMessage = L10n.text(
                "connect_vk_to_open_the_artist_page"
            )
            return
        }

        isLoading = tracks.isEmpty
        defer {
            if artist == requestedArtist {
                isLoading = false
            }
        }

        do {
            let matched: VKArtist?
            if let existing = resolvedArtist {
                matched = existing
            } else {
                matched = try await resolveArtist(named: requestedArtist)
                resolvedArtist = matched
            }
            try Task.checkCancellation()
            guard artist == requestedArtist else { return }

            let page: MusicPage<Track>
            if let matched {
                page = try await fetchArtistTracks(
                    artistID: matched.id,
                    fallbackQuery: requestedArtist
                )
            } else {
                page = try await fetchSearchPage(for: requestedArtist)
            }
            try Task.checkCancellation()
            guard artist == requestedArtist else { return }

            let filtered = ArtistTrackFilter.filtered(
                page.items,
                artist: requestedArtist
            )
            tracks = filtered.isEmpty ? page.items : filtered
            nextTracksOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard artist == requestedArtist else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Pulls the next page behind the full-track list. VK answers with the
    /// offset to continue from, so "no more" is its answer rather than a
    /// guess from the page size — a short page in the middle of a
    /// discography does not end the list early.
    @MainActor
    private func loadMoreTracks() {
        guard !isLoadingMoreTracks,
              let offset = nextTracksOffset,
              sessionStore.accessToken != nil else {
            return
        }
        let requestedArtist = artist
        let artistID = resolvedArtist?.id
        isLoadingMoreTracks = true
        loadMoreTracksTask?.cancel()
        loadMoreTracksTask = Task { @MainActor in
            defer {
                if artist == requestedArtist {
                    isLoadingMoreTracks = false
                }
            }
            do {
                let page = try await nextTracksPage(
                    artistID: artistID,
                    query: requestedArtist,
                    offset: offset
                )
                try Task.checkCancellation()
                // The artist can change while a page is in flight; appending
                // then would file one artist's tracks under another's name.
                guard artist == requestedArtist else { return }

                let filtered = ArtistTrackFilter.filtered(
                    page.items,
                    artist: requestedArtist
                )
                let incoming = filtered.isEmpty ? page.items : filtered
                var seen = Set(tracks.map(\.id))
                let unique = incoming.filter { seen.insert($0.id).inserted }
                tracks.append(contentsOf: unique)
                // Stop when VK stops offering a continuation, and also when a
                // page brought nothing new — a server that keeps handing back
                // the same rows would otherwise scroll forever.
                nextTracksOffset = unique.isEmpty ? nil : page.nextOffset
            } catch is CancellationError {
                return
            } catch {
                // A cancelled request surfaces as a transport error rather
                // than `CancellationError`, and the reload that cancelled it
                // has already cleared the offset — do not put it back.
                guard !Task.isCancelled, artist == requestedArtist else {
                    return
                }
                // Leave the list as it is and let the next scroll retry;
                // a failed page is not worth replacing the rows on screen
                // with an error state.
                nextTracksOffset = offset
            }
        }
    }

    @MainActor
    private func nextTracksPage(
        artistID: String?,
        query: String,
        offset: Int
    ) async throws -> MusicPage<Track> {
        try await withArtistDeadline {
            try await environment.withAuthorizedToken { token in
                if let artistID {
                    return try await environment.musicService.artistTracks(
                        artistID: artistID,
                        accessToken: token,
                        offset: offset,
                        count: ArtistTrackPagePolicy.pageSize
                    )
                }
                return try await environment.musicService.search(
                    query: query,
                    accessToken: token,
                    offset: offset,
                    count: ArtistTrackPagePolicy.pageSize
                )
            }
        }
    }

    @MainActor
    private func loadAlbums() async {
        let requestedArtist = artist
        guard sessionStore.accessToken != nil, !isLoadingAlbums else { return }
        isLoadingAlbums = true
        albumLoadError = nil
        defer { isLoadingAlbums = false }
        do {
            let matched = resolvedArtist
            let page: MusicPage<Album> = try await withArtistDeadline {
                try await environment.withAuthorizedToken { token in
                    if let matched {
                        return try await environment.musicService.artistAlbums(
                            artistID: matched.id, accessToken: token, offset: 0, count: 30
                        )
                    }
                    return try await environment.musicService.searchAlbums(
                        query: requestedArtist, accessToken: token, offset: 0, count: 20
                    )
                }
            }
            try Task.checkCancellation()
            guard artist == requestedArtist else { return }
            let filtered = ArtistAlbumFilter.filtered(
                page.items,
                artist: requestedArtist
            )
            let candidates = filtered.isEmpty && matched != nil
                ? page.items
                : filtered
            // Tracks may already be on screen with covers; use them to fill
            // thin album stubs and drop leftover audio-row false positives.
            albums = ArtistAlbumShelfPolicy.displaying(
                candidates,
                using: tracks
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, artist == requestedArtist else { return }
            albumLoadError = L10n.text("artist.albums.load_error")
        }
    }

    @MainActor
    private func resolveArtist(named name: String) async throws -> VKArtist? {
        let candidates = try await environment.withAuthorizedToken { token in
            try await environment.musicService.searchArtists(
                query: name,
                accessToken: token,
                offset: 0,
                count: 8
            )
        }
        return VKArtistMatch.best(in: candidates, named: name)
    }

    @MainActor
    private func fetchArtistTracks(
        artistID: String,
        fallbackQuery: String
    ) async throws -> MusicPage<Track> {
        do {
            return try await withArtistDeadline {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.artistTracks(
                        artistID: artistID,
                        accessToken: token,
                        offset: 0,
                        count: 50
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error == .timedOut {
            throw error
        } catch {
            return try await fetchSearchPage(for: fallbackQuery)
        }
    }

    @MainActor
    private func fetchSearchPage(
        for requestedArtist: String
    ) async throws -> MusicPage<Track> {
        try await withArtistDeadline {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.search(
                    query: requestedArtist,
                    accessToken: token,
                    offset: 0,
                    count: 50
                )
            }
        }
    }

    @MainActor
    private func withArtistDeadline<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(
                    for: .seconds(ArtistLoadPolicy.timeout)
                )
                throw APIError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

enum ArtistLoadPolicy {
    static let timeout: TimeInterval = 25
}

/// Paging for the artist's full track list.
enum ArtistTrackPagePolicy {
    static let pageSize = 50

    /// How close to the end of the loaded rows the list asks for more. Kept
    /// well inside the page so the next batch is already arriving before the
    /// listener reaches the bottom.
    static let prefetchDistance = 8

    static func shouldLoadMore(
        visibleIndex: Int,
        loadedCount: Int,
        hasMore: Bool,
        isLoading: Bool
    ) -> Bool {
        guard hasMore, !isLoading, loadedCount > 0 else { return false }
        return visibleIndex >= loadedCount - prefetchDistance
    }
}

enum ArtistAlbumFilter {
    static func filtered(_ albums: [Album], artist: String) -> [Album] {
        var seen = Set<String>()
        return albums.filter { album in
            ArtistTrackFilter.matches(album.artistText, artist: artist)
                && seen.insert(album.compositeID).inserted
        }
    }
}

enum ArtistTrackFilter {
    static func filtered(_ tracks: [Track], artist: String) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            matches(track.artist, artist: artist)
                && seen.insert(track.id).inserted
        }
    }

    static func matches(_ candidate: String, artist: String) -> Bool {
        let target = MixFeedbackPolicy.normalized(artist)
        guard !target.isEmpty else { return false }
        let value = MixFeedbackPolicy.normalized(candidate)
        if value == target {
            return true
        }

        return collaborationParts(in: value).contains(target)
    }

    private static func collaborationParts(in value: String) -> [String] {
        let separators = [
            ",",
            ";",
            " feat. ",
            " feat ",
            " featuring ",
            " ft. ",
            " ft "
        ]
        return separators.reduce([value]) { parts, separator in
            parts.flatMap {
                $0.components(separatedBy: separator)
            }
        }
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

}

struct ArtistLoadingView: View {
    let artist: String

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ArtistHeaderCard(name: artist, photoURL: nil, subtitle: L10n.text("loading_artist"), playbackAction: nil)
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.top, BubbleSpacing.m)
                    .padding(.bottom, BubbleSpacing.section)

                HStack {
                    Text(L10n.text("loading_artist"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(.horizontal, PremiumLayout.screenPadding)
                .padding(.bottom, 10)

                ForEach(0..<4, id: \.self) { _ in
                    ArtistLoadingRow()
                        .padding(.horizontal, PremiumLayout.screenPadding)
                        .padding(.vertical, 5)
                }
            }
        }
        .scrollDisabled(true)
        .skeletonLoading(label: "loading_artist")
    }
}

private struct ArtistLoadingRow: View {
    var body: some View { LoadingTrackRow() }
}

private struct ArtistMessageView: View {
    let title: String
    let description: String
    let systemImage: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let retry {
                Button(L10n.text("action.retry"), action: retry)
                    .buttonStyle(PremiumProminentButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ArtistInlineError: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let message: String
    let retry: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BubbleSpacing.s))
            : AnyLayout(HStackLayout(spacing: BubbleSpacing.m))
        layout {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("action.retry"), action: retry)
                .font(.caption.weight(.semibold))
                .frame(minWidth: PremiumLayout.minimumTapTarget, minHeight: PremiumLayout.minimumTapTarget)
        }
        .padding(BubbleSpacing.m)
        .premiumCard()
    }
}
