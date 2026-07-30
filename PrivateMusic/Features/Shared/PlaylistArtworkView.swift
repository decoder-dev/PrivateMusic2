import SwiftUI
import UIKit

struct PlaylistArtworkView: View {
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    let playlist: Playlist
    var size: CGFloat
    var showsSource = true

    var body: some View {
        artwork
            .overlay(alignment: .bottomLeading) {
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
        if let url = offlinePlaylists.localArtworkURL(for: playlist),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.artworkRadius(for: size),
                        style: .continuous
                    )
                )
        } else {
            AsyncArtwork(url: playlist.artworkURL, size: size)
        }
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
        .frame(height: size >= 100 ? 24 : 19)
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
