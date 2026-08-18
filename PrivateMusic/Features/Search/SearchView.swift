import SwiftUI

struct SearchView: View {
    private enum Scope: String, CaseIterable {
        case tracks = "library.tracks"
        case artists = "artists"
        case albums = "library.albums"
        case playlists = "library.playlists"

        var title: String { L10n.text(rawValue) }

        /// Segmented picker clips the full artist label on compact widths.
        var compactTitle: String {
            switch self {
            case .tracks, .albums, .playlists:
                return title
            case .artists:
                return L10n.text("artists_2")
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppSettings.self) private var settings
    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = SearchViewModel()
    @State private var scope: Scope = .tracks
    @State private var pendingLibraryTrackIDs = Set<String>()
    @State private var pendingAlbumIDs = Set<String>()
    @State private var isSystemSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    let isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        // Keep `.searchable` on the NavigationStack root (outside
        // ScrollViewReader) so the regular Search tab still has a native
        // search field on iOS 26.0+ without detached tab-bar chrome.
        searchScrollRoot
            .clearsMiniPlayer()
            .background(ThemeBackground())
            .navigationTitle(L10n.text("tab.search"))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(SystemSearchTabModifier(
                query: $model.query,
                isPresented: $isSystemSearchPresented,
                onSubmit: submitSearch,
                isEnabled: usesSystemSearchChrome
            ))
            .onChange(of: model.query) { _ in
                scheduleSearch()
            }
            .onChange(of: scope) { _ in
                loadAlbumsIfNeeded()
                loadPlaylistsIfNeeded()
            }
            .onChange(of: isActive) { active in
                if active {
                    if usesSystemSearchChrome {
                        if #available(iOS 26.0, *) {
                            isSystemSearchPresented = true
                        }
                    } else {
                        isSearchFocused = true
                    }
                    return
                }
                isSearchFocused = false
                isSystemSearchPresented = false
            }
            .alert(L10n.text("could_not_update_library"),
                isPresented: Binding(
                    get: { model.actionErrorMessage != nil },
                    set: { if !$0 { model.actionErrorMessage = nil } }
                )
            ) {
                Button(L10n.text("action.ok"), role: .cancel) {}
            } message: {
                Text(model.actionErrorMessage ?? "")
            }
    }

    private var searchScrollRoot: some View {
        ScrollViewReader { proxy in
            searchLayout(showsCustomField: showsInlineSearchField)
                .onChange(of: scrollCoordinator.request) { _, request in
                    guard request?.destination == .search else { return }
                    isSearchFocused = false
                    isSystemSearchPresented = false
                    if reduceMotion {
                        proxy.scrollTo(
                            MainTabScrollDestination.search,
                            anchor: .top
                        )
                    } else {
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo(
                                MainTabScrollDestination.search,
                                anchor: .top
                            )
                        }
                    }
                }
        }
    }

    /// Inline field when the legacy dock owns bottom chrome (pre–iOS 26 or
    /// classic player look on iOS 26). System tabs use `.searchable` instead.
    private var usesSystemSearchChrome: Bool {
        if #available(iOS 26.0, *) {
            return SearchChromePolicy.usesSystemSearchChrome(
                isIOS26OrLater: true,
                classicChrome: settings.classicChrome
            )
        }
        return false
    }

    private var showsInlineSearchField: Bool {
        !usesSystemSearchChrome
    }

    private func searchLayout(showsCustomField: Bool) -> some View {
        VStack(spacing: 0) {
            if showsCustomField {
                searchField
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.top, BubbleSpacing.s)
                    .padding(.bottom, BubbleSpacing.m)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                L10n.text("track_artist_album_or_playlist"),
                text: $model.query
            )
            .focused($isSearchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                submitSearch()
            }
            .accessibilityLabel(L10n.text("search_query"))
            .accessibilityHint(
                L10n.text("enter_at_least_two_characters")
            )

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("clear_search"))
            }
        }
        .padding(.horizontal, BubbleSpacing.m)
        .frame(minHeight: 48)
        .background(
            settings.theme.surface.opacity(0.82),
            in: searchFieldShape
        )
        .overlay {
            searchFieldShape.stroke(.primary.opacity(0.1), lineWidth: 0.7)
        }
        .clipShape(searchFieldShape)
        .contentShape(searchFieldShape)
        .onTapGesture {
            guard isActive else { return }
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            searchLanding
        case .needsMoreCharacters:
            SearchStatusView(
                title: "enter_one_more_character",
                systemImage: "character.cursor.ibeam",
                description: "search_requires_at_least_two_characters"
            )
        case .loading:
            searchLoading
        case .results:
            searchResults
        case .empty:
            searchResults
        case let .failure(message):
            SearchStatusView(
                title: "search_error",
                systemImage: "wifi.exclamationmark",
                description: message,
                descriptionIsLocalizedKey: false,
                actionTitle: "action.retry",
                action: submitSearch
            )
        }
    }

    private var searchTopAnchor: some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .id(MainTabScrollDestination.search)
            .accessibilityHidden(true)
    }

    private var searchLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                VStack(alignment: .leading, spacing: BubbleSpacing.s) {
                    PremiumSectionHeader(
                        "find_music",
                        subtitle:
                            "enter_a_track_title_or_artist_results_appear_automatically"
                    )
                }

                if !model.recentQueries.isEmpty {
                    recentQueries
                }
            }
            .id(MainTabScrollDestination.search)
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.top, BubbleSpacing.l)
            .padding(.bottom, BubbleSpacing.section)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var recentQueries: some View {
        AppGroupedSection(title: "search.recent") {
            Button(L10n.text("clear")) {
                model.clearRecent()
            }
            .font(.system(size: 13, weight: .semibold))
            .accessibilityLabel(L10n.text("clear_recent_searches"))
        } content: {
            ForEach(Array(model.recentQueries.enumerated()), id: \.element) {
                index, query in
                HStack(spacing: BubbleSpacing.s) {
                    Button {
                        model.useRecent(query)
                    } label: {
                        AppGroupedRow {
                            HStack(spacing: BubbleSpacing.s) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(query)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        } trailing: {
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("search_again_for_0", query))

                    Button {
                        model.removeRecent(query)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .minimumHitTarget(visualSize: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format("remove_search_0", query)
                    )
                }
                .padding(.trailing, BubbleSpacing.m)
                if index < model.recentQueries.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private var searchLoading: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.text("search.searching"))
                .font(.headline)
            Text(model.normalizedQuery)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("searching"))
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            AppGroupedSurface {
                Picker(L10n.text("search_type"), selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) {
                        Text($0.compactTitle).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, BubbleSpacing.xs)
                .padding(.vertical, BubbleSpacing.xs)
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.bottom, BubbleSpacing.s)

            if scope == .tracks, let error = model.errorMessage {
                inlineRetry(message: error, action: submitSearch)
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, BubbleSpacing.s)
            }

            if scope == .tracks {
                if model.tracks.isEmpty {
                    SearchStatusView(
                        title: "no_tracks_found",
                        systemImage: "music.note",
                        description:
                            "try_the_albums_artists_or_playlists_tab"
                    )
                } else {
                    trackResults
                }
            } else if scope == .artists {
                if model.artists.isEmpty {
                    SearchStatusView(
                        title: "no_artists_found",
                        systemImage: "person.wave.2",
                        description: "try_changing_your_query"
                    )
                } else {
                    artistResults
                }
            } else if scope == .albums {
                if model.isLoadingAlbums && model.albums.isEmpty {
                    searchLoading
                } else if let error = model.albumErrorMessage,
                          model.albums.isEmpty {
                    SearchStatusView(
                        title: "album_search_failed",
                        systemImage: "wifi.exclamationmark",
                        description: error,
                        descriptionIsLocalizedKey: false,
                        actionTitle: "action.retry",
                        action: submitSearch
                    )
                } else if model.albums.isEmpty {
                    SearchStatusView(
                        title: "no_albums_found",
                        systemImage: "square.stack",
                        description: "try_changing_your_query"
                    )
                } else {
                    albumResults
                }
            } else {
                if model.isLoadingPlaylists && model.playlists.isEmpty {
                    searchLoading
                } else if let error = model.playlistErrorMessage,
                          model.playlists.isEmpty {
                    SearchStatusView(
                        title: "playlist_search_failed",
                        systemImage: "wifi.exclamationmark",
                        description: error,
                        descriptionIsLocalizedKey: false,
                        actionTitle: "action.retry",
                        action: submitSearch
                    )
                } else if model.playlists.isEmpty {
                    SearchStatusView(
                        title: "no_playlists_found",
                        systemImage: "rectangle.stack",
                        description: "try_changing_your_query"
                    )
                } else {
                    playlistResults
                }
            }
        }
    }

    private var trackResults: some View {
        List {
            searchTopAnchor
            ForEach(model.tracks) { track in
                TrackRow(track: track, queue: model.tracks)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if track.id == model.tracks.last?.id {
                            loadMore()
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            add(track)
                        } label: {
                            Label(
                                L10n.text(
                                    libraryStore.contains(track)
                                        ? "added"
                                        : "add_to_library"
                                ),
                                systemImage:
                                    libraryStore.contains(track)
                                    ? "checkmark"
                                    : "plus"
                            )
                        }
                        .tint(settings.theme.accent)
                        .disabled(
                            libraryStore.contains(track)
                                || pendingLibraryTrackIDs.contains(track.id)
                        )
                    }
            }

            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView(L10n.text("loading_more"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let message = model.paginationErrorMessage {
                inlineRetry(message: message, action: loadMore)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var artistResults: some View {
        List {
            searchTopAnchor
            ForEach(model.artists, id: \.self) { artist in
                NavigationLink {
                    ArtistView(artist: artist)
                } label: {
                    searchArtistRow(artist)
                }
                .listRowBackground(Color.clear)
                .onAppear {
                    if artist == model.artists.last {
                        loadMore()
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
            } else if let message = model.paginationErrorMessage {
                inlineRetry(message: message, action: loadMore)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var albumResults: some View {
        List {
            searchTopAnchor
            ForEach(model.albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    searchAlbumRow(album)
                }
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button {
                        toggleAlbum(album)
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
                .onAppear {
                    if album.id == model.albums.last?.id {
                        loadMoreAlbums()
                    }
                }
            }
            if model.isLoadingMoreAlbums {
                HStack {
                    Spacer()
                    ProgressView(L10n.text("loading_more"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let message = model.albumErrorMessage {
                inlineRetry(message: message, action: loadMoreAlbums)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var playlistResults: some View {
        List {
            searchTopAnchor
            ForEach(
                Array(model.playlists.enumerated()),
                id: \.element.searchIdentity
            ) { index, playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    searchPlaylistRow(playlist)
                }
                .buttonStyle(PremiumPressStyle())
                .listRowBackground(Color.clear)
                .premiumAppear(delay: min(Double(index) * 0.025, 0.2))
                .onAppear {
                    if playlist.searchIdentity
                        == model.playlists.last?.searchIdentity {
                        loadMorePlaylists()
                    }
                }
            }
            if model.isLoadingMorePlaylists {
                HStack {
                    Spacer()
                    ProgressView(L10n.text("loading_more"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let message = model.playlistErrorMessage {
                inlineRetry(message: message, action: loadMorePlaylists)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func inlineRetry(
        message: String,
        action: @escaping () -> Void
    ) -> some View {
        AppInlineMessageCard(
            message: message,
            systemImage: "exclamationmark.circle",
            actionTitle: L10n.text("action.retry"),
            action: action
        )
    }

    private var searchFieldShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.controlRadius,
            style: .continuous
        )
    }

    private func searchArtistRow(_ artist: String) -> some View {
        AppGroupedRow {
            HStack(spacing: BubbleSpacing.m) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 24)
                Text(artist)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func searchAlbumRow(_ album: Album) -> some View {
        AppGroupedRow(minHeight: 64) {
            HStack(spacing: BubbleSpacing.m) {
                AsyncArtwork(url: album.artworkURL, size: 56)
                VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                    Text(
                        Album.isUsableTitle(album.title)
                            ? album.title
                            : L10n.text("album")
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(album.artistText)
                        .font(BubbleType.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(L10n.trackCount(album.count))
                        .font(BubbleType.micro)
                        .foregroundStyle(.tertiary)
                }
            }
        } trailing: {
            if likedAlbumsStore.isFollowed(album) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(settings.theme.accent)
            }
        }
    }

    private func searchPlaylistRow(_ playlist: Playlist) -> some View {
        AppGroupedRow(minHeight: 64) {
            HStack(spacing: BubbleSpacing.m) {
                PlaylistArtworkView(
                    playlist: playlist,
                    size: 56,
                    showsSource: false
                )
                VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.trackCount(playlist.count))
                        .font(BubbleType.metadata)
                        .foregroundStyle(.secondary)
                    Text(L10n.format("from_0", playlist.source.title))
                        .font(BubbleType.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func scheduleSearch() {
        guard sessionStore.accessToken != nil else { return }
        model.schedule(operation: search)
        if scope == .albums {
            model.scheduleAlbums(operation: searchAlbums)
        } else if scope == .playlists {
            model.schedulePlaylists(operation: searchPlaylists)
        }
    }

    private func submitSearch() {
        guard sessionStore.accessToken != nil else { return }
        model.submit(operation: search)
        if scope == .albums {
            model.submitAlbums(operation: searchAlbums)
        } else if scope == .playlists {
            model.submitPlaylists(operation: searchPlaylists)
        }
    }

    private func loadAlbumsIfNeeded() {
        guard sessionStore.accessToken != nil, scope == .albums else { return }
        model.submitAlbums(operation: searchAlbums)
    }

    private func loadPlaylistsIfNeeded() {
        guard sessionStore.accessToken != nil,
              scope == .playlists else { return }
        model.submitPlaylists(operation: searchPlaylists)
    }

    private func search(
        query: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        try await environment.withAuthorizedToken { token in
            try await environment.musicService.search(
                query: query,
                accessToken: token,
                offset: offset,
                count: count
            )
        }
    }

    private func searchAlbums(
        query: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        try await environment.withAuthorizedToken { token in
            try await environment.musicService.searchAlbums(
                query: query,
                accessToken: token,
                offset: offset,
                count: count
            )
        }
    }

    private func searchPlaylists(
        query: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist> {
        let page = try await environment.withAuthorizedToken { token in
            try await environment.musicService.playlists(
                accessToken: token,
                offset: offset,
                count: count
            )
        }
        // Folded once here; matching itself runs in PrivateMusicCore.c.
        let needle = FoldedSearchQuery(query)
        let filtered = page.items.filter { playlist in
            needle.matches(playlist.title)
                || (playlist.description.map(needle.matches) ?? false)
        }
        return MusicPage(
            items: filtered,
            totalCount: filtered.count,
            nextOffset: page.nextOffset
        )
    }

    private func add(_ track: Track) {
        guard sessionStore.accessToken != nil,
              pendingLibraryTrackIDs.insert(track.id).inserted else {
            return
        }
        Task {
            defer { pendingLibraryTrackIDs.remove(track.id) }
            if let added = await model.add(
                track,
                operation: { item in
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.addToLibrary(
                            item,
                            accessToken: token
                        )
                    }
                }
            ) {
                libraryStore.markAdded(source: track, stored: added)
            }
        }
    }

    private func loadMore() {
        guard sessionStore.accessToken != nil else { return }
        Task {
            await model.loadMore(operation: search)
        }
    }

    private func loadMoreAlbums() {
        guard sessionStore.accessToken != nil else { return }
        Task {
            await model.loadMoreAlbums(operation: searchAlbums)
        }
    }

    private func loadMorePlaylists() {
        guard sessionStore.accessToken != nil else { return }
        Task {
            await model.loadMorePlaylists(operation: searchPlaylists)
        }
    }

    private func toggleAlbum(_ album: Album) {
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
            } catch {
                model.actionErrorMessage = error.localizedDescription
            }
        }
    }
}

/// Binds system search chrome for the regular Search tab on iOS 26.0+ when
/// the system tab bar is in use. Classic / legacy dock keeps the inline field.
private struct SystemSearchTabModifier: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let onSubmit: () -> Void
    var isEnabled: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), isEnabled {
            content
                .searchable(
                    text: $query,
                    isPresented: $isPresented,
                    placement: .automatic,
                    prompt: Text(
                        L10n.text(
                            "track_artist_album_or_playlist"
                        )
                    )
                )
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

private extension Playlist {
    var searchIdentity: String {
        "\(ownerID)_\(id)"
    }
}

private struct SearchStatusView: View {
    let title: String
    let systemImage: String
    let description: String
    var descriptionIsLocalizedKey = true
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        AppStatusPanel(
            title: title,
            systemImage: systemImage,
            description: description,
            descriptionIsLocalizedKey: descriptionIsLocalizedKey,
            actionTitle: actionTitle,
            action: action
        )
    }
}
