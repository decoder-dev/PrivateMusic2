import SwiftUI

struct AlbumDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likedAlbumsStore: LikedAlbumsStore
    @EnvironmentObject private var settings: AppSettings
    let album: Album
    @StateObject private var model = AlbumDetailViewModel()
    @State private var isUpdatingFollow = false
    @State private var actionErrorMessage: String?

    var body: some View {
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
                    ProgressView("Загружаем ещё…")
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
        .background(ThemeBackground())
        .navigationTitle(displayedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isLoading && model.tracks.isEmpty {
                ProgressView("Загружаем альбом…")
            } else if model.hasLoaded && model.tracks.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        title: model.errorMessage == nil
                            ? "В альбоме нет доступных треков"
                            : "Не удалось открыть альбом",
                        systemImage: model.errorMessage == nil
                            ? "music.note.list"
                            : "wifi.exclamationmark",
                        description: model.errorMessage
                            ?? "VK не вернул доступные аудиозаписи."
                    )
                    Button("Повторить") {
                        Task { await load(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 32)
                }
                .background(ThemeBackground())
            }
        }
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .alert(
            "Не удалось изменить альбом",
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

    private var albumHeader: some View {
        VStack(spacing: 14) {
            AsyncArtwork(url: displayedAlbum.artworkURL, size: 190)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            VStack(spacing: 5) {
                Text(displayedTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
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
                Button(action: toggleFollow) {
                    Image(systemName: isFollowed ? "heart.fill" : "heart")
                        .foregroundStyle(
                            isFollowed ? Color.red : settings.theme.accent
                        )
                        .frame(width: 46, height: 46)
                }
                .adaptiveGlass(in: Circle(), interactive: true)
                .buttonStyle(PremiumPressStyle())
                .disabled(isUpdatingFollow)
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(settings.theme.accent)
                            .frame(width: 46, height: 46)
                    }
                    .adaptiveGlass(in: Circle(), interactive: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// A play icon inside a wide Label pushes the text off-center (the
    /// icon+text group is centered as a unit, but the icon's width isn't
    /// mirrored on the trailing side). Centering the text on its own and
    /// pinning the icon to the leading edge keeps "Слушать" dead-center
    /// regardless of button width.
    private var listenButtonLabel: some View {
        ZStack {
            Text(L10n.text("Слушать"))
                .font(.headline)
            HStack {
                Image(systemName: "play.fill")
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
            Button(action: playAlbum) {
                listenButtonLabel
            }
            .buttonStyle(.glassProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        } else {
            Button(action: playAlbum) {
                listenButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.theme.accent)
            .disabled(model.tracks.isEmpty)
        }
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
        album.normalized(using: model.tracks)
    }

    private var displayedTitle: String {
        Album.isUsableTitle(displayedAlbum.title)
            ? displayedAlbum.title
            : L10n.text("Альбом")
    }

    private func playAlbum() {
        guard let first = model.tracks.first else { return }
        player.play(
            first,
            in: model.tracks,
            source: .album(title: displayedTitle)
        )
    }

    private func toggleFollow() {
        guard !isUpdatingFollow else { return }
        let desired = !isFollowed
        isUpdatingFollow = true
        Task {
            defer { isUpdatingFollow = false }
            do {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.toggleAlbumFollow(
                        displayedAlbum,
                        accessToken: token
                    )
                }
                if desired {
                    likedAlbumsStore.markFollowed(displayedAlbum)
                } else {
                    likedAlbumsStore.markUnfollowed(displayedAlbum)
                }
                NotificationCenter.default.post(
                    name: .likedAlbumsDidChange,
                    object: nil
                )
                Haptics.success()
            } catch {
                actionErrorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func load(force: Bool) async {
        guard sessionStore.accessToken != nil else { return }
        await model.load(force: force) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.albumTracks(
                    album,
                    accessToken: token,
                    offset: 0,
                    count: 100
                )
            }
        }
    }

    private func loadMore() async {
        await model.loadMore { offset in
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.albumTracks(
                    album,
                    accessToken: token,
                    offset: offset,
                    count: 100
                )
            }
        }
    }
}

@MainActor
private final class AlbumDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?
    @Published var paginationErrorMessage: String?
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
