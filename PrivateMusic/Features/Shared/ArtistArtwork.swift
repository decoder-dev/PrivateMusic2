import SwiftUI

/// Portraits have their own fallback: an album cover is not an artist photo.
/// Search rows reuse this view without making a separate network lookup.
struct ArtistArtwork: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let name: String
    var url: URL?
    var size: CGFloat = 56

    var body: some View {
        CachedRemoteImage(url: url, maxPixelSize: max(128, size * displayScale)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                settings.surfaceColor
                LinearGradient(colors: [settings.accent.opacity(0.18), settings.accent.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                let initials = ArtistArtworkPolicy.initials(for: name)
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.34, weight: .medium))
                } else {
                    Text(initials)
                        // dynamic-type-exempt: decorative monogram inside a fixed portrait, hidden from accessibility.
                        .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(settings.accent)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

enum ArtistArtworkPolicy {
    static func portraitURL(for artist: VKArtist?) -> URL? {
        guard let artist, !artist.isAlbumCover else { return nil }
        return artist.photoURL
    }

    static func initials(for name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return "" }
        if words.count == 1 {
            let count = first.count <= 3 ? 3 : 2
            return String(first.uppercased().prefix(count))
        }
        return words.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }
}
