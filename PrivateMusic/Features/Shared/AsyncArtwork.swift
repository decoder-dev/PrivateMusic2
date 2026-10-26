import SwiftUI

struct AsyncArtwork: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let url: URL?
    var size: CGFloat
    var placeholderText: String? = nil

    var body: some View {
        CachedRemoteImage(
            url: url,
            maxPixelSize: max(size * displayScale, 128)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            if let placeholderText {
                Text(placeholderText)
                    // dynamic-type-exempt: decorative artwork identity, not the accessible track label.
                    .font(.system(size: size * 0.32, weight: .light, design: .rounded))
                    .foregroundStyle(settings.accent.opacity(0.75))
                    .accessibilityHidden(true)
            } else {
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
