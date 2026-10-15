import Foundation

enum MixBootstrapPrefetch {
    /// Warm the first few artworks after a mix page arrives so the player
    /// and hub cards paint instantly. Audio neighbor preload stays in
    /// `AudioPlayer` (next-only) to avoid stream spam.
    static func artwork(
        for tracks: [Track],
        limit: Int = 4,
        maxPixelSize: CGFloat = 512
    ) {
        guard DecorativeWorkPolicy.allowsSpeculativeWork
        else { return }
        var seen = Set<URL>()
        let urls = tracks.prefix(limit).compactMap(\.artworkURL).filter { seen.insert($0).inserted }
        guard !urls.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.makeIterator()
                for _ in 0..<min(2, urls.count) {
                    if let url = iterator.next() {
                        group.addTask { await ArtworkImageCache.shared.prefetch(url: url, maxPixelSize: maxPixelSize) }
                    }
                }
                for await _ in group {
                    guard !Task.isCancelled,
                          DecorativeWorkPolicy.allowsSpeculativeWork
                    else { group.cancelAll(); return }
                    if let url = iterator.next() {
                        group.addTask { await ArtworkImageCache.shared.prefetch(url: url, maxPixelSize: maxPixelSize) }
                    }
                }
            }
        }
    }
}
