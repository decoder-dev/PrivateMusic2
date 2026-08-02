import SwiftUI
import UIKit
import ImageIO

struct CachedRemoteImage<
    Content: View,
    Placeholder: View
>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    var maxPixelSize: CGFloat = 1_200
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
        let pixelSize = max(maxPixelSize, 64)
        if let cached = ArtworkImageCache.shared.image(
            for: url,
            maxPixelSize: pixelSize
        ) {
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
                  let loaded = await ArtworkImageCache.downsample(
                    data,
                    maxPixelSize: pixelSize
                  ) else {
                if loadedURL != url {
                    withAnimation(.easeOut(duration: 0.16)) {
                        image = nil
                        loadedURL = nil
                    }
                }
                return
            }
            ArtworkImageCache.shared.insert(
                loaded,
                for: url,
                maxPixelSize: pixelSize
            )
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
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 96 * 1_024 * 1_024

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 48 * 1_024 * 1_024,
            diskCapacity: 192 * 1_024 * 1_024,
            diskPath: "PrivateMusic.Artwork"
        )
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(for: url, maxPixelSize: maxPixelSize))
    }

    func insert(
        _ image: UIImage,
        for url: URL,
        maxPixelSize: CGFloat
    ) {
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        cache.setObject(
            image,
            forKey: key(for: url, maxPixelSize: maxPixelSize),
            cost: width * height * 4
        )
    }

    static func downsample(
        _ data: Data,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded(.up))
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return UIImage(cgImage: image)
        }.value
    }

    private func key(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let bucket = Int((maxPixelSize / 128).rounded(.up)) * 128
        return "\(url.absoluteString)#\(bucket)" as NSString
    }
}
