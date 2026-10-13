import CoreImage
import SwiftUI
import UIKit

/// A story-sized card (cover, title, artist) drawn on the device. It is
/// rendered to an image and handed to the system share sheet, so it works
/// with VK and Instagram stories, messages and the camera roll alike.
struct TrackShareCard: View {
    static let size = CGSize(width: 360, height: 640)

    let title: String
    let artist: String
    let artwork: UIImage?
    let background: Color
    let footer: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [background, background.opacity(0.55), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 28) {
                Spacer(minLength: 0)
                cover
                VStack(spacing: 8) {
                    Text(title)
                        // dynamic-type-exempt: the card is an image of a fixed size, not live UI.
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Text(artist)
                        // dynamic-type-exempt: the card is an image of a fixed size, not live UI.
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                Spacer(minLength: 0)
                Text(footer)
                    // dynamic-type-exempt: the card is an image of a fixed size, not live UI.
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 36)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var cover: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: 80, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

/// Builds the card image: loads the cover, picks a background from it and
/// renders at story resolution (1080 × 1920).
@MainActor
enum TrackShareCardRenderer {
    static func render(for track: Track) async -> UIImage? {
        var artwork: UIImage?
        if let url = track.artworkURL {
            await ExportArtworkLoader.prefetch(url)
            artwork = ArtworkImageCache.shared.image(for: url, maxPixelSize: 512)
        }
        let card = TrackShareCard(
            title: track.title,
            artist: track.artist,
            artwork: artwork,
            background: artwork.flatMap(dominantColor) ?? Color(white: 0.2),
            footer: L10n.text("private_music")
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage
    }

    /// Average colour of the cover, darkened so white text stays readable.
    private static func dominantColor(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent)
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let scale = 0.62
        return Color(
            red: Double(pixel[0]) / 255 * scale,
            green: Double(pixel[1]) / 255 * scale,
            blue: Double(pixel[2]) / 255 * scale
        )
    }
}

/// Preview of the card with the share button.
struct TrackShareCardSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: BubbleSpacing.l) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(radius: 12, y: 6)
                        .accessibilityLabel(L10n.text("share_card.preview"))
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview(track.title, image: Image(uiImage: image))
                    ) {
                        Label(L10n.text("share_card.share"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
                    }
                    .buttonStyle(PremiumProminentButtonStyle())
                } else if failed {
                    Text(L10n.text("share_card.failed"))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(L10n.text("share_card.preparing"))
                }
            }
            .padding(PremiumLayout.screenPadding)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeBackground())
            .navigationTitle(L10n.text("share_card.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("done")) { dismiss() }
                }
            }
        }
        .task(id: track.id) {
            image = nil
            failed = false
            image = await TrackShareCardRenderer.render(for: track)
            failed = image == nil
        }
    }
}
