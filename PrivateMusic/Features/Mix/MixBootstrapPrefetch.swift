import Foundation

enum MixBootstrapPrefetch {
    /// Warm the first few artworks after a mix page arrives so the player
    /// and hub cards paint instantly. Audio neighbor preload stays in
    /// `AudioPlayer` (next-only) to avoid stream spam.
    static func artwork(
        for tracks: [Track],
        limit: Int = 8,
        maxPixelSize: CGFloat = 512
    ) {
        let urls = tracks.prefix(limit).compactMap(\.artworkURL)
        guard !urls.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        await ArtworkImageCache.shared.prefetch(
                            url: url,
                            maxPixelSize: maxPixelSize
                        )
                    }
                }
            }
        }
    }
}
