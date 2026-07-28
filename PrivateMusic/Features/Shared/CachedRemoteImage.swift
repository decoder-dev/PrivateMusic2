import SwiftUI
import UIKit

struct CachedRemoteImage<
    Content: View,
    Placeholder: View
>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = ArtworkImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await ArtworkImageCache.shared.session
                .data(from: url)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let loaded = UIImage(data: data) else {
                return
            }
            ArtworkImageCache.shared.insert(loaded, for: url)
            image = loaded
        } catch {
            return
        }
    }
}

private final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 96 * 1_024 * 1_024

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 48 * 1_024 * 1_024,
            diskCapacity: 0,
            diskPath: nil
        )
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
