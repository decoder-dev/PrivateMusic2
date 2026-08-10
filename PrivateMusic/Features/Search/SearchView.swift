import SwiftUI

struct SearchView: View {
    private enum Scope: String, CaseIterable {
        case tracks = "Треки"
        case artists = "Исполнители"
        case albums = "Альбомы"
        case playlists = "Плейлисты"

        var title: String { L10n.text(rawValue) }

        /// Segmented picker clips the full artist label on compact widths.
        var compactTitle: String {
            switch self {
            case .tracks, .albums, .playlists:
                return title
            case .artists:
                return L10n.text("Артисты")
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @EnvironmentObject private var likedAlbumsStore: LikedAlbumsStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = SearchViewModel()
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
        // ScrollViewReader) so Tab(role: .search) + tabViewSearchActivation
        // can bind the system search field on iOS 26.0+.
        searchScrollRoot
            .background(ThemeBackground())
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(SystemSearchTabModifier(
                query: $model.query,
                isPresented: $isSystemSearchPresented,
                onSubmit: submitSearch
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
                    // Activate the system search field when the search tab
                    // is selected (belt-and-suspenders with tab activation).
                    if #available(iOS 26.0, *) {
                        isSystemSearchPresented = true
                    }
                    return
                }
                isSearchFocused = false
                isSystemSearchPresented = false
            }
            .alert(
                "Не удалось изменить медиатеку",
                isPresented: Binding(
                    get: { model.actionErrorMessage != nil },
                    set: { if !$0 { model.actionErrorMessage = nil } }
                )
            ) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(model.actionErrorMessage ?? "")
            }
    }

    private var searchScrollRoot: some View {
        ScrollViewReader { proxy in
            searchLayout(showsCustomField: showsInlineSearchField)
                .onReceive(scrollCoordinator.$request) { request in
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

    /// Inline field only on the pre–iOS 26 custom dock path. System tabs
    /// use `.searchable` instead so the search tab is not empty.
    private var showsInlineSearchField: Bool {
        if #available(iOS 26.0, *) {
            return false
        }
        return true
    }

    private func searchLayout(showsCustomField: Bool) -> some View {
        VStack(spacing: 0) {
            if showsCustomField {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
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
                L10n.text("Трек, исполнитель, альбом или плейлист"),
                text: $model.query
            )
            .focused($isSearchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                submitSearch()
            }
            .accessibilityLabel(L10n.text("Поисковый запрос"))
            .accessibilityHint(
                L10n.text("Введите не менее двух символов")
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
                .accessibilityLabel(L10n.text("Очистить поиск"))
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 48)
        .background(
            settings.theme.surface,
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
                title: "Введите ещё один символ",
                systemImage: "character.cursor.ibeam",
                description: "Для поиска нужно минимум два символа."
            )
        case .loading:
            searchLoading
        case .results:
            searchResults
        case .empty:
            searchResults
        case let .failure(message):
            SearchStatusView(
                title: "Ошибка поиска",
                systemImage: "wifi.exclamationmark",
                description: message,
                actionTitle: "Повторить",
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
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.text("Найдите музыку"),
                        systemImage: "music.note"
                    )
                    .font(.title2.weight(.bold))
                    Text(
                        L10n.text(
                            "Введите название трека или исполнителя. "
                                + "Результаты появятся автоматически."
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !model.recentQueries.isEmpty {
                    recentQueries
                }
            }
            .id(MainTabScrollDestination.search)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var recentQueries: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Недавние запросы")
                    .font(.headline)
                Spacer()
                Button("Очистить") {
                    model.clearRecent()
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel(
                    L10n.text("Очистить недавние запросы")
                )
            }
            .padding(.bottom, 4)

            ForEach(model.recentQueries, id: \.self) { query in
                HStack(spacing: 8) {
                    Button {
                        model.useRecent(query)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text(query)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format("Повторить поиск «%@»", query)
                    )

                    Button {
                        model.removeRecent(query)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format("Удалить запрос «%@»", query)
                    )
                }
                .frame(minHeight: 48)
            }
        }
        .padding(16)
        .premiumCard()
    }

    private var searchLoading: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Ищем в VK…")
                .font(.headline)
            Text(model.normalizedQuery)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Выполняется поиск"))
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            Picker("Тип поиска", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) {
                    Text($0.compactTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if scope == .tracks, let error = model.errorMessage {
                inlineRetry(message: error, action: submitSearch)
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, 8)
            }

            if scope == .tracks {
                if model.tracks.isEmpty {
                    SearchStatusView(
                        title: "Треки не найдены",
                        systemImage: "music.note",
                        description:
                            "Попробуйте вкладку альбомов, исполнителей или плейлистов."
                    )
                } else {
                    trackResults
                }
            } else if scope == .artists {
                if model.artists.isEmpty {
                    SearchStatusView(
                        title: "Исполнители не найдены",
                        systemImage: "person.wave.2",
                        description: "Попробуйте изменить запрос."
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
                        title: "Ошибка поиска альбомов",
                        systemImage: "wifi.exclamationmark",
                        description: error,
                        actionTitle: "Повторить",
                        action: submitSearch
                    )
                } else if model.albums.isEmpty {
                    SearchStatusView(
                        title: "Альбомы не найдены",
                        systemImage: "square.stack",
                        description: "Попробуйте изменить запрос."
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
                        title: "Ошибка поиска плейлистов",
                        systemImage: "wifi.exclamationmark",
                        description: error,
                        actionTitle: "Повторить",
                        action: submitSearch
                    )
                } else if model.playlists.isEmpty {
                    SearchStatusView(
                        title: "Плейлисты не найдены",
                        systemImage: "rectangle.stack",
                        description: "Попробуйте изменить запрос."
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
                                        ? "Добавлено"
                                        : "В медиатеку"
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
                    ProgressView("Загружаем ещё…")
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
                    Label(artist, systemImage: "person.wave.2")
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
                    ProgressView("Загружаем ещё…")
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
                    HStack(spacing: 12) {
                        AsyncArtwork(url: album.artworkURL, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                Album.isUsableTitle(album.title)
                                    ? album.title
                                    : L10n.text("Альбом")
                            )
                                .font(.headline)
                                .lineLimit(2)
                            Text(album.artistText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(L10n.trackCount(album.count))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if likedAlbumsStore.isFollowed(album) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(settings.theme.accent)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button {
                        toggleAlbum(album)
                    } label: {
                        Label(
                            likedAlbumsStore.isFollowed(album)
                                ? "Удалить альбом из медиатеки"
                                : "Добавить альбом в медиатеку",
                            systemImage: likedAlbumsStore.isFollowed(album)
                                ? "heart.slash"
                                : "heart"
                        )
                    }
                    .disabled(pendingAlbumIDs.contains(album.compositeID))
                    if let url = AlbumShareLinkBuilder.url(for: album) {
                        ShareLink(item: url) {
                            Label(
                                "Поделиться ссылкой",
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
                    ProgressView("Загружаем ещё…")
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
                    HStack(spacing: 12) {
                        PlaylistArtworkView(
                            playlist: playlist,
                            size: 56,
                            showsSource: false
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(L10n.trackCount(playlist.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                L10n.format(
                                    "Из %@",
                                    playlist.source.title
                                )
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
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
                    ProgressView("Загружаем ещё…")
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
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Повторить", action: action)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color.orange.opacity(settings.theme == .dark ? 0.12 : 0.09),
            in: inlineMessageShape
        )
        .overlay {
            inlineMessageShape.stroke(
                Color.orange.opacity(settings.theme == .dark ? 0.28 : 0.2),
                lineWidth: 0.7
            )
        }
        .clipShape(inlineMessageShape)
        .contentShape(inlineMessageShape)
    }

    private var searchFieldShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.controlRadius,
            style: .continuous
        )
    }

    private var inlineMessageShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.compactRadius,
            style: .continuous
        )
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
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        let filtered = page.items.filter { playlist in
            playlist.title.searchMatches(normalized)
                || (playlist.description?.searchMatches(normalized) ?? false)
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

/// Binds system search chrome for `Tab(role: .search)` on iOS 26.0+.
/// Older OS versions keep the inline custom field in `SearchView`.
private struct SystemSearchTabModifier: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let onSubmit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchable(
                    text: $query,
                    isPresented: $isPresented,
                    placement: .automatic,
                    prompt: Text(
                        L10n.text(
                            "Трек, исполнитель, альбом или плейлист"
                        )
                    )
                )
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

private extension String {
    func searchMatches(_ normalizedQuery: String) -> Bool {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .contains(normalizedQuery)
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
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(L10n.text(actionTitle), action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
