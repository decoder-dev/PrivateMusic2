import SwiftUI

struct NewReleasesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
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

                            Button { playAlbum(album) } label: {
                                Group {
                                    if loadingPlayAlbumID == album.id {
                                        ProgressView()
                                            .tint(.black)
                                    } else {
                                        Image(systemName: "play.fill")
                                    }
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(.white, in: Circle())
                            }
                            .buttonStyle(PremiumPressStyle())
                            .padding(8)
                            .disabled(loadingPlayAlbumID != nil)
                            .accessibilityLabel(L10n.text("Воспроизвести альбом"))
                        }
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    Album.isUsableTitle(album.title)
                                        ? album.title
                                        : L10n.text("Альбом")
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
        .background(ThemeBackground())
        .navigationTitle(L10n.text("Новые релизы"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Не удалось воспроизвести альбом",
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
                let title = Album.isUsableTitle(album.title)
                    ? album.title
                    : L10n.text("Альбом")
                environment.player.play(
                    first,
                    in: page.items,
                    source: .album(title: title)
                )
            } catch is CancellationError {
                return
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }
}
