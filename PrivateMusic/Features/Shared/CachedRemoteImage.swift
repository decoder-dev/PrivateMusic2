import SwiftUI
import UIKit
import ImageIO

struct CachedRemoteImage<
    Content: View,
    Placeholder: View
>: View {
    let url: URL?
    var maxPixelSize: CGFloat = 1_200
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var fallbackImage: UIImage?
    @State private var loadedIdentity: LoadIdentity?
    @State private var loadingIdentity: LoadIdentity?

    var body: some View {
        let displayedImage = loadedIdentity == loadIdentity ? image : nil
        let visibleImage = displayedImage
            ?? (loadingIdentity == loadIdentity ? fallbackImage : nil)

        ZStack {
            placeholder()
                .opacity(visibleImage == nil ? 1 : 0)
            if let image = visibleImage {
                content(Image(uiImage: image))
            }
        }
        .task(id: loadIdentity) {
            await load(loadIdentity)
        }
    }

    private var loadIdentity: LoadIdentity {
        let requestedSize = maxPixelSize.isFinite ? maxPixelSize : 1_200
        let bucket = max(
            Int((requestedSize / 128).rounded(.up)) * 128,
            128
        )
        return LoadIdentity(url: url, pixelSize: bucket)
    }

    @MainActor
    private func load(_ identity: LoadIdentity) async {
        if loadedIdentity != identity {
            // Keep the last settled bitmap visible while the replacement loads,
            // but only for that load's lifetime — a failed request must still
            // end on the placeholder instead of leaving the wrong artwork up.
            fallbackImage = image
            image = nil
            loadedIdentity = nil
        }

        guard let url = identity.url else {
            fallbackImage = nil
            loadingIdentity = nil
            return
        }
        loadingIdentity = identity
        let pixelSize = CGFloat(identity.pixelSize)
        if let cached = ArtworkImageCache.shared.image(
            for: url,
            maxPixelSize: pixelSize
        ) {
            image = cached
            loadedIdentity = identity
            fallbackImage = nil
            loadingIdentity = nil
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
            guard !Task.isCancelled,
                  loadIdentity == identity else {
                return
            }
            guard let loaded = await ArtworkImageCache.downsample(
                    data,
                    maxPixelSize: pixelSize
                  ) else { return }
            guard !Task.isCancelled, loadIdentity == identity else { return }
            ArtworkImageCache.shared.insert(
                loaded,
                for: url,
                maxPixelSize: pixelSize
            )
            image = loaded
            loadedIdentity = identity
            fallbackImage = nil
            if loadingIdentity == identity {
                loadingIdentity = nil
            }
        } catch is CancellationError {
            if loadingIdentity == identity {
                loadingIdentity = nil
            }
            return
        } catch {
            guard loadIdentity == identity else { return }
            image = nil
            loadedIdentity = nil
            if loadingIdentity == identity {
                loadingIdentity = nil
            }
            return
        }
    }

    private struct LoadIdentity: Hashable {
        let url: URL?
        let pixelSize: Int
    }
}

private actor ArtworkPrefetchRegistry {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: Set<UUID>
    }

    static let shared = ArtworkPrefetchRegistry()
    private var entries: [String: Entry] = [:]

    func prefetch(
        cache: ArtworkImageCache,
        url: URL,
        maxPixelSize: CGFloat
    ) async {
        let bucket = max(
            Int((maxPixelSize / 128).rounded(.up)) * 128,
            128
        )
        let key = "\(url.absoluteString)#\(bucket)"
        let waiterID = UUID()
        let entryID: UUID
        let task: Task<Void, Never>
        if var existing = entries[key] {
            existing.waiters.insert(waiterID)
            entries[key] = existing
            entryID = existing.id
            task = existing.task
        } else {
            entryID = UUID()
            task = Task {
                await cache.performPrefetch(
                    url: url,
                    maxPixelSize: CGFloat(bucket)
                )
            }
            entries[key] = Entry(
                id: entryID,
                task: task,
                waiters: [waiterID]
            )
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.release(
                    key: key,
                    entryID: entryID,
                    waiterID: waiterID,
                    cancelWhenUnused: true
                )
            }
        }
        release(
            key: key,
            entryID: entryID,
            waiterID: waiterID,
            cancelWhenUnused: false
        )
    }

    private func release(
        key: String,
        entryID: UUID,
        waiterID: UUID,
        cancelWhenUnused: Bool
    ) {
        guard var entry = entries[key],
              entry.id == entryID,
              entry.waiters.remove(waiterID) != nil else {
            return
        }
        guard entry.waiters.isEmpty else {
            entries[key] = entry
            return
        }
        entries[key] = nil
        if cancelWhenUnused {
            entry.task.cancel()
        }
    }
}

final class ArtworkImageCache: @unchecked Sendable {
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

    func prefetch(url: URL?, maxPixelSize: CGFloat) async {
        guard let url else { return }
        await ArtworkPrefetchRegistry.shared.prefetch(
            cache: self,
            url: url,
            maxPixelSize: maxPixelSize
        )
    }

    fileprivate func performPrefetch(
        url: URL,
        maxPixelSize: CGFloat
    ) async {
        guard image(for: url, maxPixelSize: maxPixelSize) == nil else {
            return
        }
        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else {
                let (remoteData, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return
                }
                data = remoteData
            }
            guard !Task.isCancelled,
                  let artwork = await Self.downsample(
                    data,
                    maxPixelSize: maxPixelSize
                  ) else {
                return
            }
            insert(artwork, for: url, maxPixelSize: maxPixelSize)
        } catch {
            return
        }
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
