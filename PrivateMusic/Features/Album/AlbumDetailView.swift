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

    var body: some View {
        List {
            Section {
                albumHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.tracks) { track in
                TrackRow(track: track, queue: model.tracks)
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
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isLoading && model.tracks.isEmpty {
                ProgressView("Загружаем альбом…")
            } else if let error = model.errorMessage,
                      model.tracks.isEmpty {
                EmptyStateView(
                    title: "Не удалось открыть альбом",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
                .background(ThemeBackground())
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: toggleFollow) {
                        Label(
                            isFollowed
                                ? "Удалить альбом из медиатеки"
                                : "Добавить альбом в медиатеку",
                            systemImage: isFollowed ? "heart.slash" : "heart"
                        )
                    }
                    .disabled(isUpdatingFollow)
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label(
                                "Поделиться ссылкой",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
    }

    private var albumHeader: some View {
        VStack(spacing: 14) {
            AsyncArtwork(url: album.artworkURL, size: 190)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            VStack(spacing: 5) {
                Text(album.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(album.artistText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let releaseDate = album.releaseDate {
                    Text(releaseDate.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(L10n.trackCount(album.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(action: playAlbum) {
                    Label("Слушать", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.tracks.isEmpty)
                Button(action: toggleFollow) {
                    Image(systemName: isFollowed ? "heart.fill" : "heart")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(settings.theme.accent)
                .disabled(isUpdatingFollow)
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var isFollowed: Bool {
        likedAlbumsStore.isFollowed(album)
    }

    private var shareURL: URL? {
        AlbumShareLinkBuilder.url(for: album)
    }

    private func playAlbum() {
        guard let first = model.tracks.first else { return }
        player.play(first, in: model.tracks)
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
                        album,
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
                player.errorMessage = error.localizedDescription
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
    @Published var errorMessage: String?
    private var nextOffset: Int?

    func load(
        force: Bool,
        operation: () async throws -> MusicPage<Track>
    ) async {
        guard !isLoading,
              !isLoadingMore,
              force || tracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await operation()
            tracks = page.items
            nextOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
