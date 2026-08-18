import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(LikedAlbumsStore.self) private var likedAlbumsStore
    @Environment(AppSettings.self) private var settings
    @Environment(AudioPlayer.self) private var player
    let album: Album
    @State private var model = AlbumDetailViewModel()
    @State private var resolvedAlbum: Album?
    @State private var isUpdatingFollow = false
    @State private var actionErrorMessage: String?
    @State private var showsNavTitle = false

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
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 32)
                }
            } else {
                albumList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
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
                    .listRowSeparator(.hidden)
            }
            ForEach(model.tracks) { track in
                TrackRow(
                    track: track,
                    queue: model.tracks,
                    source: .album(title: displayedTitle)
                )
                .listRowBackground(Color.clear)
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
            } else if let error = model.paginationErrorMessage {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .listRowBackground(Color.clear)
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
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
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
            HStack(spacing: 12) {
                listenButton
                shuffleButton
                Button(action: toggleFollow) {
                    Image(systemName: isFollowed ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(
                            isFollowed ? Color.red : settings.theme.accent
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
                            .foregroundStyle(settings.theme.accent)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .adaptiveGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text("share_album"))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// A play icon inside a wide Label pushes the text off-center (the
    /// icon+text group is centered as a unit, but the icon's width isn't
    /// mirrored on the trailing side). Centering the text on its own and
    /// pinning the icon to the leading edge keeps "listen" dead-center
    /// regardless of button width.
    private var listenButtonLabel: some View {
        ZStack {
            Text(L10n.text(listenAction == .pause ? "pause_2" : "listen"))
                .font(.headline)
            HStack {
                Image(systemName: listenAction.systemImage)
                    .accessibilityHidden(true)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var listenButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(.glassProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        } else {
            Button(action: toggleListen) {
                listenButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        }
    }

    private var shuffleButton: some View {
        Button(action: shuffleAlbum) {
            Image(systemName: "shuffle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(settings.theme.accent)
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
