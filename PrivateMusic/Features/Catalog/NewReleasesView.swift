import SwiftUI

struct NewReleasesView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PlaybackHighlightModel.self) private var highlight
    let albums: [Album]

    @State private var loadingPlayAlbumID: String?
    @State private var actionErrorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AsyncArtwork(url: album.artworkURL, size: 150)
                            }
                            .buttonStyle(PremiumPressStyle())

                            let playbackAction = playbackAction(for: album)
                            Button {
                                performPlaybackAction(
                                    playbackAction,
                                    for: album
                                )
                            } label: {
                                Group {
                                    if loadingPlayAlbumID == album.id {
                                        ProgressView()
                                            .tint(.black)
                                    } else {
                                        Image(
                                            systemName:
                                                playbackAction.systemImage
                                        )
                                    }
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(.white, in: Circle())
                            }
                            .buttonStyle(PremiumPressStyle())
                            .padding(8)
                            .disabled(
                                loadingPlayAlbumID != nil
                                    && loadingPlayAlbumID != album.id
                            )
                            .accessibilityLabel(
                                L10n.text(
                                    playbackAction.accessibilityLabelKey(
                                        playKey: "play_album"
                                    )
                                )
                            )
                        }
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    Album.isUsableTitle(album.title)
                                        ? album.title
                                        : L10n.text("album")
                                )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                Text(album.artistText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .clearsMiniPlayer(includingWhenDockReservesSpace: true)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("new_releases"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.text("could_not_play_album"),
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

    private func playbackAction(for album: Album) -> QueueSourcePlaybackAction {
        QueueSourcePlaybackAction.resolve(
            target: albumQueueSource(for: album),
            isPlaying: highlight.isPlaying,
            queueSource: highlight.queueSource
        )
    }

    private func performPlaybackAction(
        _ action: QueueSourcePlaybackAction,
        for album: Album
    ) {
        switch action {
        case .start:
            playAlbum(album)
        case .resume:
            environment.player.resume()
        case .pause:
            environment.player.pause()
        }
    }

    private func albumQueueSource(for album: Album) -> QueueSource {
        .album(title: albumPlaybackTitle(album))
    }

    private func albumPlaybackTitle(_ album: Album) -> String {
        Album.isUsableTitle(album.title) ? album.title : L10n.text("album")
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
                environment.player.play(
                    first,
                    in: page.items,
                    source: albumQueueSource(for: album)
                )
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }
}
