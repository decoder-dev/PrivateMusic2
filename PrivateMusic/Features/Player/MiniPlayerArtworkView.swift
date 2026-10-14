import SwiftUI
import UIKit

/// Artwork that keeps the previous bitmap visible until the next image is
/// ready, then swaps it in place — avoiding the placeholder flash of
/// `.id(track.id)`. The swap is immediate; there is no crossfade.
struct MiniPlayerArtworkView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale

    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = MiniPlayerLayoutMetrics.artworkCornerRadius
    var showsShadow: Bool = true

    @State private var displayedImage: UIImage?
    @State private var loadGeneration = 0
    @State private var displayedURL: URL?

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        ZStack {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .shadow(
            color: showsShadow ? .black.opacity(0.18) : .clear,
            radius: showsShadow
                ? MiniPlayerLayoutMetrics.artworkShadowRadius
                : 0,
            y: showsShadow ? MiniPlayerLayoutMetrics.artworkShadowY : 0
        )
        .accessibilityHidden(true)
        .task(id: url) {
            await loadArtwork(for: url)
        }
    }

    private var placeholder: some View {
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

    @MainActor
    private func loadArtwork(for url: URL?) async {
        loadGeneration += 1
        let generation = loadGeneration
        let pixelSize = max(size * displayScale, 128)

        guard let url else {
            await clearToPlaceholder(generation: generation)
            return
        }

        if displayedURL == url, displayedImage != nil {
            return
        }

        // Keep the last settled frame visible until the new one is ready.
        if let cached = ArtworkImageCache.shared.image(
            for: url,
            maxPixelSize: pixelSize
        ) {
            await present(
                cached,
                url: url,
                generation: generation
            )
            return
        }

        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else {
                let (remoteData, response) = try await ArtworkImageCache
                    .shared.session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                data = remoteData
            }
            guard generation == loadGeneration else { return }
            guard let loaded = await ArtworkImageCache.downsample(
                data,
                maxPixelSize: pixelSize
            ) else {
                return
            }
            guard generation == loadGeneration else { return }
            ArtworkImageCache.shared.insert(
                loaded,
                for: url,
                maxPixelSize: pixelSize
            )
            await present(loaded, url: url, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            // Keep the previous artwork on failure when we have one.
            if displayedImage == nil {
                await clearToPlaceholder(generation: generation)
            }
        }
    }

    @MainActor
    private func present(
        _ image: UIImage,
        url: URL,
        generation: Int
    ) async {
        guard generation == loadGeneration else { return }
        BubbleTintCache.shared.recordArtwork(image, for: url)
        displayedImage = image
        displayedURL = url
    }

    @MainActor
    private func clearToPlaceholder(generation: Int) async {
        guard generation == loadGeneration else { return }
        displayedImage = nil
        displayedURL = nil
    }
}
