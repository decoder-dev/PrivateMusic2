import SwiftUI

struct ArtistView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: String
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var resolvedArtist: VKArtist?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedAlbum: Album?
    @State private var showsAllTracks = false
    @State private var pendingAlbumIDs = Set<String>()
    @State private var albumActionErrorMessage: String?
    /// Where the next page of tracks starts, or `nil` once VK has no more.
    /// The first load used to throw this away, which is why the artist page
    /// stopped dead at its first 50 tracks.
    @State private var nextTracksOffset: Int?
    @State private var isLoadingMoreTracks = false
    @State private var loadMoreTracksTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            Group {
                if isLoading && tracks.isEmpty {
                    ArtistLoadingView(artist: artist)
                } else if tracks.isEmpty {
                    emptyContent
                } else {
                    trackContent
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: isLoading
        )
        .sheet(item: $selectedAlbum) { album in
            NavigationStack { AlbumDetailView(album: album) }
        }
        .alert(
            "could_not_play_album",
            isPresented: Binding(
                get: { albumActionErrorMessage != nil },
                set: { if !$0 { albumActionErrorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(albumActionErrorMessage ?? "")
        }
        .onDisappear { loadMoreTracksTask?.cancel() }
        .task(id: artist) {
            resolvedArtist = nil
            if sessionStore.accessToken != nil {
                resolvedArtist = try? await resolveArtist(named: artist)
            }
            // Tracks first so album cards can inherit count/artwork from the
            // same screen instead of painting sparse «0 треков» stubs.
            await load(resetContent: true)
            await loadAlbums()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("artist"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(artist)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: Circle()
                    )
                    .minimumHitTarget(visualSize: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("action.close"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    private var trackContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                artistHeader

                if let errorMessage {
                    ArtistInlineError(
                        message: errorMessage,
                        retry: { Task { await load(resetContent: false) } }
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }

                tracksSection
                    .padding(.top, 10)

                if !albums.isEmpty {
                    albumsSection
                        .padding(.top, 18)
                }
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await load(resetContent: false)
        }
        .sheet(isPresented: $showsAllTracks) {
            NavigationStack {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) {
                        index, track in
                        TrackRow(
                            track: track,
                            queue: tracks
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

    private static let trackPreviewLimit = 16

    private var previewTracks: [Track] {
        Array(tracks.prefix(Self.trackPreviewLimit))
    }

    private var trackGridRows: [GridItem] {
        Array(repeating: GridItem(.fixed(60), spacing: 4), count: 4)
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("artist_tracks"))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(L10n.trackCount(tracks.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if tracks.count > Self.trackPreviewLimit {
                    Button {
                        showsAllTracks = true
                    } label: {
                        HStack(spacing: 2) {
                            Text(L10n.text("see_all"))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.theme.accent)
                    }
                }
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: trackGridRows, spacing: 4) {
                    ForEach(previewTracks) { track in
                        TrackRow(track: track, queue: tracks)
                            .frame(width: 264)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("library.albums"))
                .font(.headline)
                .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        artistAlbumCard(album)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 4)
    }

    private func artistAlbumCard(_ album: Album) -> some View {
        Button {
            Haptics.selection()
            selectedAlbum = album
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AsyncArtwork(url: album.artworkURL, size: 116)
                Text(
                    Album.isUsableTitle(album.title)
                        ? album.title
                        : L10n.text("album")
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(L10n.trackCount(album.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button {
                performArtistAlbumPlaybackAction(
                    artistAlbumPlaybackAction(for: album),
                    for: album
                )
            } label: {
                Label(
                    L10n.text("listen"),
                    systemImage: "play.fill"
                )
            }
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
        guard sessionStore.accessToken != nil else { return }
        Task {
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
                    source: artistAlbumQueueSource(for: album)
                )
            } catch is CancellationError {
                return
            } catch {
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
                albumActionErrorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private var artistHeader: some View {
        HStack(spacing: 16) {
            AsyncArtwork(
                url: resolvedArtist?.photoURL ?? tracks.first?.artworkURL,
                size: 88
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(artist)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.82)
                Text(
                    resolvedArtist == nil
                        ? L10n.text("generic.music")
                        : L10n.text("vk_artist")
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var emptyContent: some View {
        ArtistMessageView(
            title: L10n.text("artist_unavailable"),
            description: errorMessage
                ?? L10n.text(
                    "vk_did_not_return_any_available_tracks_for_this_artist"
                ),
            systemImage: errorMessage == nil
                ? "music.note.list"
                : "exclamationmark.circle",
            retry: sessionStore.accessToken == nil
                ? nil
                : { Task { await load(resetContent: true) } }
        )
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
        guard sessionStore.accessToken != nil else { return }
        do {
            let matched = resolvedArtist
            let page: MusicPage<Album>
            if let matched {
                page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.artistAlbums(
                        artistID: matched.id,
                        accessToken: token,
                        offset: 0,
                        count: 30
                    )
                }
            } else {
                page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.searchAlbums(
                        query: requestedArtist,
                        accessToken: token,
                        offset: 0,
                        count: 20
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
        } catch {
            return
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

private struct ArtistLoadingView: View {
    let artist: String

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    RoundedRectangle(
                        cornerRadius:
                            PremiumLayout.artworkRadius(for: 88),
                        style: .continuous
                    )
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(artist)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 104, height: 12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)

                HStack {
                    Text(L10n.text("loading_artist"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

                ForEach(0..<4, id: \.self) { _ in
                    ArtistLoadingRow()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)
                }
            }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("loading_artist"))
    }
}

private struct ArtistLoadingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: 52),
                style: .continuous
            )
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(maxWidth: 190)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(maxWidth: 120)
                    .frame(height: 10)
            }

            Spacer()
        }
        .frame(minHeight: 56)
    }
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
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArtistInlineError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.text("action.retry"), action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(
                cornerRadius: PremiumLayout.controlRadius,
                style: .continuous
            )
        )
    }
}
