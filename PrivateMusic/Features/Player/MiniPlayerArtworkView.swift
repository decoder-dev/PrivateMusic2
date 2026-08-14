import SwiftUI
import UIKit

/// Artwork that keeps the previous bitmap visible until the next image is
/// ready, then crossfades — avoiding the placeholder flash of `.id(track.id)`.
struct MiniPlayerArtworkView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = MiniPlayerLayoutMetrics.artworkCornerRadius
    var showsShadow: Bool = true

    @State private var displayedImage: UIImage?
    @State private var incomingImage: UIImage?
    @State private var incomingOpacity: Double = 0
    @State private var loadGeneration = 0
    @State private var displayedURL: URL?

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        ZStack {
            if displayedImage == nil, incomingImage == nil {
                placeholder
            }

            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(incomingImage == nil ? 1 : 1 - incomingOpacity)
            }

            if let incomingImage {
                Image(uiImage: incomingImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(incomingOpacity)
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

        // Abort any in-flight crossfade; keep the last settled frame visible.
        incomingImage = nil
        incomingOpacity = 0

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

        if displayedImage == nil {
            displayedImage = image
            displayedURL = url
            incomingImage = nil
            incomingOpacity = 0
            return
        }

        if displayedURL == url {
            displayedImage = image
            return
        }

        incomingImage = image
        incomingOpacity = 0
        let duration = reduceMotion
            ? MiniPlayerLayoutMetrics.reduceMotionCrossfadeDuration
            : MiniPlayerLayoutMetrics.trackCrossfadeDuration
        withAnimation(.easeInOut(duration: duration)) {
            incomingOpacity = 1
        }
        let nanoseconds = UInt64(max(duration, 0) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard generation == loadGeneration else { return }
        displayedImage = image
        displayedURL = url
        incomingImage = nil
        incomingOpacity = 0
    }

    @MainActor
    private func clearToPlaceholder(generation: Int) async {
        guard generation == loadGeneration else { return }
        if displayedImage == nil {
            displayedURL = nil
            incomingImage = nil
            incomingOpacity = 0
            return
        }
        let duration = reduceMotion
            ? MiniPlayerLayoutMetrics.reduceMotionCrossfadeDuration
            : MiniPlayerLayoutMetrics.trackCrossfadeDuration
        withAnimation(.easeInOut(duration: duration)) {
            incomingOpacity = 0
            displayedImage = nil
        }
        displayedURL = nil
        incomingImage = nil
    }
}
