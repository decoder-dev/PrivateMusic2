import SwiftUI

/// Rasterize only a small image layer. A full-screen drawingGroup followed by
/// blur makes every composite use a display-sized offscreen texture.
struct PlayerArtworkBackdrop: View, Equatable {
    let artworkURL: URL?
    let background: Color
    let gradient: [Color]
    let isLight: Bool
    let reduceTransparency: Bool
    @State private var allowsArtwork = DecorativeWorkPolicy.allowsSpeculativeWork

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artworkURL == rhs.artworkURL && lhs.background == rhs.background
            && lhs.gradient == rhs.gradient && lhs.isLight == rhs.isLight
            && lhs.reduceTransparency == rhs.reduceTransparency
    }

    var body: some View {
        ZStack {
            background
            if allowsArtwork, !reduceTransparency, let artworkURL {
                GeometryReader { proxy in
                    let scale = max(max(proxy.size.width, proxy.size.height), 1)
                        / PlayerArtworkBackgroundPolicy.rasterSide
                    CachedRemoteImage(url: artworkURL, maxPixelSize: PlayerArtworkBackgroundPolicy.maxPixelSize) { image in
                        image.resizable().scaledToFill()
                            .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                            .blur(radius: PlayerArtworkBackgroundPolicy.blurRadius / scale)
                            .clipped()
                            .drawingGroup(opaque: false)
                    } placeholder: { Color.clear }
                    .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                    .scaleEffect(scale * 1.28)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .opacity(isLight ? 0.18 : 1)
                }
            }
            background.opacity(isLight ? 0.72 : 0.56)
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            allowsArtwork = DecorativeWorkPolicy.allowsSpeculativeWork
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            allowsArtwork = DecorativeWorkPolicy.allowsSpeculativeWork
        }
    }
}
