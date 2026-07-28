import SwiftUI
import UIKit

actor TrackShareService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func prepareFile(for track: Track) async throws -> URL {
        guard let streamURL = track.streamURL else {
            throw APIError.invalidRequest
        }
        let (temporaryURL, response) = try await session.download(
            from: streamURL
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        if http.expectedContentLength > 150_000_000 {
            throw APIError.server(
                code: 413,
                message: "Файл больше 150 МБ."
            )
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard !mime.contains("mpegurl"),
              !mime.contains("m3u") else {
            throw APIError.server(
                code: 415,
                message: "Этот поток нельзя экспортировать одним файлом."
            )
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporaryURL.path
        )
        let size = attributes[.size] as? NSNumber
        guard size?.int64Value ?? 0 <= 150_000_000 else {
            throw APIError.server(
                code: 413,
                message: "Файл больше 150 МБ."
            )
        }

        let extensionName = fileExtension(
            response: http,
            sourceURL: streamURL
        )
        let name = safeFilename("\(track.artist) — \(track.title)")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
            .appendingPathExtension(extensionName)
        try FileManager.default.copyItem(
            at: temporaryURL,
            to: destination
        )
        return destination
    }

    private func fileExtension(
        response: HTTPURLResponse,
        sourceURL: URL
    ) -> String {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac"].contains(sourceExtension) {
            return sourceExtension
        }
        switch response.mimeType?.lowercased() {
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/flac": "flac"
        default: "m4a"
        }
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = value.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(90)).isEmpty
            ? "Private Music"
            : String(cleaned.prefix(90))
    }
}

struct TrackShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
