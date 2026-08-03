import SwiftUI

struct NewReleasesView: View {
    let albums: [Album]

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AsyncArtwork(url: album.artworkURL, size: 150)
                            Text(
                                Album.isUsableTitle(album.title)
                                    ? album.title
                                    : L10n.text("Альбом")
                            )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(album.artistText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PremiumPressStyle())
                }
            }
            .padding(16)
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("Новые релизы"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
