import SwiftUI

/// Useful destinations, with no extra catalog requests or playback observation.
struct HomeQuickAccessView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(LikedAlbumsStore.self) private var albums
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
            NavigationLink { ListeningHistoryView() } label: {
                tile("listening_history", icon: "clock.arrow.circlepath", artworkURL: history.entries.first?.track.artworkURL)
            }
            NavigationLink { LibraryView(section: .playlists) } label: {
                tile("library.playlists", icon: "music.note.list")
            }
            NavigationLink { LibraryView(section: .albums) } label: {
                tile("library.albums", icon: "square.stack", artworkURL: albums.albums.first?.artworkURL)
            }
            NavigationLink { MixesHubView() } label: {
                tile("home.quick.mixes", icon: "sparkles")
            }
        }
        .buttonStyle(PremiumPressStyle())
    }

    private func tile(_ title: String, icon: String, artworkURL: URL? = nil) -> some View {
        HStack(spacing: 10) {
            Group {
                if let artworkURL {
                    AsyncArtwork(url: artworkURL, size: 48)
                } else {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(settings.accent)
                        .frame(width: 48, height: 48)
                        .background(settings.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
