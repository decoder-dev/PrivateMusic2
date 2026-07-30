import SwiftUI
import UIKit

struct CachedRemoteImage<
    Content: View,
    Placeholder: View
>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            placeholder()
                .opacity(image == nil ? 1 : 0)
            if let image {
                content(Image(uiImage: image))
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: loadedURL
        )
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }
        if let cached = ArtworkImageCache.shared.image(for: url) {
            image = cached
            loadedURL = url
            return
        }
        do {
            let (data, response) = try await ArtworkImageCache.shared.session
                .data(from: url)
            guard !Task.isCancelled,
                  self.url == url else {
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let loaded = UIImage(data: data) else {
                if loadedURL != url {
                    withAnimation(.easeOut(duration: 0.16)) {
                        image = nil
                        loadedURL = nil
                    }
                }
                return
            }
            ArtworkImageCache.shared.insert(loaded, for: url)
            image = loaded
            loadedURL = url
        } catch is CancellationError {
            return
        } catch {
            guard self.url == url, loadedURL != url else { return }
            image = nil
            loadedURL = nil
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
