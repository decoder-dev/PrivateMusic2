import SwiftUI
import UIKit

struct AsyncArtwork: View {
    @EnvironmentObject private var settings: AppSettings
    let url: URL?
    var size: CGFloat

    var body: some View {
        CachedRemoteImage(
            url: url,
            maxPixelSize: max(size * UIScreen.main.scale, 128)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [
                        settings.theme.secondaryAccent,
                        settings.theme.secondaryAccent
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(settings.theme.accent)
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
