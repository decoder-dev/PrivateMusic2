import SwiftUI
import UIKit

enum TrackSharePayload: Equatable, Sendable {
    case audioFile(URL)
    case vkLink(url: URL, description: String)

    var exportedFileURL: URL? {
        guard case let .audioFile(url) = self else { return nil }
        return url
    }

    var identifier: String {
        switch self {
        case let .audioFile(url):
            return "file-\(url.absoluteString)"
        case let .vkLink(url, _):
            return "link-\(url.absoluteString)"
        }
    }
}

actor TrackShareService {
    static let maximumFileSize: Int64 = 150_000_000

    private let session: URLSession
    private let fileManager: FileManager

    init(
        session: URLSession? = nil,
        fileManager: FileManager = .default
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
    }

    /// Creates a real audio attachment when VK exposes a direct audio file.
    /// HLS addresses are temporary playlists, so they are shared as a stable
    /// VK page instead of exposing signed segment URLs or attempting DRM bypass.
    func preparePayload(
        for track: Track,
        userAgent: String?
    ) async throws -> TrackSharePayload {
        guard let streamURL = track.streamURL else {
            return linkPayload(for: track)
        }
        guard !isHLS(streamURL) else {
            return linkPayload(for: track)
        }

        var request = URLRequest(url: streamURL)
        request.timeoutInterval = 60
        for (field, value) in requestHeaders(userAgent: userAgent) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        guard !isHLS(response: http) else {
            return linkPayload(for: track)
        }
        guard isAudioResponse(http, sourceURL: streamURL) else {
            throw APIError.invalidResponse
        }
        guard http.expectedContentLength <= Self.maximumFileSize
                || http.expectedContentLength < 0 else {
            throw fileTooLargeError
        }
        guard try fileSize(at: temporaryURL) <= Self.maximumFileSize else {
            throw fileTooLargeError
        }

        let destination = exportDestination(
            for: track,
            extensionName: fileExtension(
                response: http,
                sourceURL: streamURL
            )
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destination)
        }
        return .audioFile(destination)
    }

    func linkPayload(for track: Track) -> TrackSharePayload {
        let url = URL(
            string: "https://vk.com/audio\(track.ownerID)_\(track.trackID)"
        )!
        let description = [track.artist, track.title]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " — ")
        return .vkLink(
            url: url,
            description: description.isEmpty
                ? "Private Music"
                : description
        )
    }

    func removeExportedFile(_ payload: TrackSharePayload) {
        guard let url = payload.exportedFileURL,
              url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL
                == fileManager.temporaryDirectory.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private var fileTooLargeError: APIError {
        APIError.server(
            code: 413,
            message: L10n.text("Файл больше 150 МБ.")
        )
    }

    private func isHLS(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame
    }

    private func isHLS(response: HTTPURLResponse) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        return mime.contains("mpegurl")
            || mime.contains("m3u")
            || response.url.map(isHLS) == true
    }

    private func isAudioResponse(
        _ response: HTTPURLResponse,
        sourceURL: URL
    ) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("audio/") {
            return true
        }
        let fileExtension = sourceURL.pathExtension.lowercased()
        return mime == "application/octet-stream"
            && ["mp3", "m4a", "aac", "wav", "flac"].contains(fileExtension)
    }

    private func requestHeaders(userAgent: String?) -> [String: String] {
        var headers = [
            "Referer": "https://vk.com/",
            "Origin": "https://vk.com"
        ]
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        return headers
    }

    private func exportDestination(
        for track: Track,
        extensionName: String
    ) -> URL {
        let name = safeFilename("\(track.artist) — \(track.title)")
        return fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
            .appendingPathExtension(extensionName)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
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
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/flac": return "flac"
        default: return "m4a"
        }
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = String(cleaned.prefix(90))
        return shortened.isEmpty ? "Private Music" : shortened
    }
}

struct TrackShareSheet: UIViewControllerRepresentable {
    let payload: TrackSharePayload

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let activityItems: [Any]
        switch payload {
        case let .audioFile(fileURL):
            activityItems = [fileURL]
        case let .vkLink(url, description):
            activityItems = [description, url]
        }
        return UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
