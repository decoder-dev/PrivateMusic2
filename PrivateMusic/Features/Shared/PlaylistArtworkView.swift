import SwiftUI

struct PlaylistArtworkView: View {
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    let playlist: Playlist
    var size: CGFloat
    var showsSource = true

    var body: some View {
        artwork
            .overlay(alignment: .topTrailing) {
                if showsSource {
                    sourceBadge
                        .padding(max(6, size * 0.065))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.format(
                    "%@, импортировано из %@",
                    playlist.title,
                    playlist.source.title
                )
            )
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = offlinePlaylists.localArtworkURL(for: playlist) {
            CachedRemoteImage(
                url: url,
                maxPixelSize: max(size * 3, 128)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: size, height: size)
            .clipShape(artworkShape)
        } else if playlist.artworkURL != nil {
            AsyncArtwork(url: playlist.artworkURL, size: size)
        } else {
            // Missing cover: keep note muted/centered — AsyncArtwork's
            // accent-blue note sat under the VK badge and looked broken.
            artworkPlaceholder
                .frame(width: size, height: size)
                .clipShape(artworkShape)
        }
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .offset(y: showsSource ? size * 0.04 : 0)
            }
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.artworkRadius(for: size),
            style: .continuous
        )
    }

    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Text(playlist.source.shortTitle)
                .font(.system(size: max(9, size * 0.08), weight: .bold))
            if size >= 100 {
                Text("Музыка")
                    .font(.system(size: max(8, size * 0.07), weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, size >= 100 ? 8 : 6)
        .frame(height: size >= 100 ? 22 : 18)
        .background(
            Color(red: 0.0, green: 0.47, blue: 0.96).opacity(0.96),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }
}
