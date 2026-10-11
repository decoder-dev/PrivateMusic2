import Foundation

/// A cover is optional: short timeout and a byte limit keep audio export responsive.
enum ExportArtworkLoader {
    static func prefetch(_ url: URL) async {
        if ArtworkImageCache.shared.image(for: url, maxPixelSize: 512) != nil { return }
        guard url.scheme == "https" else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.hasPrefix("image/") == true,
                  http.expectedContentLength <= 2_000_000 else { return }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_000_000 else { return }
                data.append(byte)
            }
            try Task.checkCancellation()
            if let image = await ArtworkImageCache.downsample(data, maxPixelSize: 512) {
                ArtworkImageCache.shared.insert(image, for: url, maxPixelSize: 512)
            }
        } catch { return }
    }
}
