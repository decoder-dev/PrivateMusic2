import SwiftUI

/// Decorative blurred artwork behind the Home hero. Isolated so transport
/// ticks and play-state flips do not re-blur the layer on every frame.
struct HomeStageAtmosphereLayer: View {
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(AppSettings.self) private var settings

    let width: CGFloat
    let horizontalPadding: CGFloat
    let foregroundTopOrigin: CGFloat
    /// When false the mask ends with the transport row instead of
    /// bleeding into an empty context-rail band.
    var hasRail: Bool = true

    var body: some View {
        ZStack {
            if let artworkURL = highlight.currentTrackArtworkURL {
                CachedRemoteImage(
                    url: artworkURL,
                    maxPixelSize: HomeStageAtmospherePolicy.maxPixelSize
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        // Overscan so the blur does not sample empty
                        // pixels at the bled left/right edges.
                        .scaleEffect(HomeStageAtmospherePolicy.overscan)
                        .blur(radius: HomeStageAtmospherePolicy.blurRadius)
                        .saturation(1.15)
                        .opacity(settings.theme == .light ? 0.22 : 0.64)
                } placeholder: {
                    Color.clear
                }
                .id(artworkURL)
            } else {
                idleAtmosphereTint
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: HomeStageMetrics.atmosphereHeight(
                for: width,
                topSafeAreaInset: foregroundTopOrigin,
                hasRail: hasRail
            )
        )
        .clipped()
        .drawingGroup(opaque: false)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.25), location: 0.55),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.horizontal, -horizontalPadding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var idleAtmosphereTint: some View {
        let tint = BubblePalette.surface(.station, tint: nil).color
        return LinearGradient(
            colors: [
                tint.opacity(settings.theme == .light ? 0.10 : 0.20),
                .clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

enum HomeStageAtmospherePolicy {
    /// Home sits in a vertical scroll — keep decode + blur cheaper than
    /// the full-screen player background.
    static let maxPixelSize: CGFloat = 240
    static let blurRadius: CGFloat = 36
    /// Enough overscan that a 36pt blur still has pixels at the frame edge.
    static let overscan: CGFloat = 1.15
}
