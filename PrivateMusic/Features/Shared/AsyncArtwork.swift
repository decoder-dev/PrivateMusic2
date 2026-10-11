import SwiftUI

struct AsyncArtwork: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let url: URL?
    var size: CGFloat

    var body: some View {
        CachedRemoteImage(
            url: url,
            maxPixelSize: max(size * displayScale, 128)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                settings.surfaceColor
                LinearGradient(
                    colors: [
                        settings.accent.opacity(0.08),
                        settings.accent.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(settings.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size),
                style: .continuous
            )
        )
    }
}
