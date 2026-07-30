import SwiftUI
import UIKit

enum TrackSharePayload: Equatable, Sendable {
    case audioFile(URL)

    var fileURL: URL {
        switch self {
        case let .audioFile(url):
            return url
        }
    }

    var identifier: String {
        switch self {
        case let .audioFile(url):
            return "file-\(url.absoluteString)"
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
    /// HLS playlists are deliberately rejected: renaming or linking a playlist
    /// does not create an MP3 and would expose a temporary signed address.
    func preparePayload(
        for track: Track,
        userAgent: String?,
        requiresMP3: Bool = false
    ) async throws -> TrackSharePayload {
        guard let streamURL = track.streamURL else {
            throw directAudioUnavailableError
        }
        guard !isHLS(streamURL) else {
            throw directAudioUnavailableError
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
            throw directAudioUnavailableError
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
        guard !isHLSFile(at: temporaryURL) else {
            throw directAudioUnavailableError
        }
        if requiresMP3 {
            guard http.mimeType?.lowercased() == "audio/mpeg",
                  isLikelyMP3(at: temporaryURL) else {
                throw directMP3UnavailableError
            }
        }

        let destination = exportDestination(
            for: track,
            extensionName: try fileExtension(
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

    func payloadFromLocalFile(
        _ sourceURL: URL,
        track: Track,
        requiresMP3: Bool = true
    ) throws -> TrackSharePayload {
        guard sourceURL.isFileURL,
              fileManager.fileExists(atPath: sourceURL.path) else {
            throw directAudioUnavailableError
        }
        if requiresMP3 {
            guard sourceURL.pathExtension.lowercased() == "mp3",
                  isLikelyMP3(at: sourceURL) else {
                throw directMP3UnavailableError
            }
        }
        let destination = exportDestination(
            for: track,
            extensionName: sourceURL.pathExtension.isEmpty
                ? "mp3"
                : sourceURL.pathExtension
        )
        do {
            try fileManager.linkItem(at: sourceURL, to: destination)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        return .audioFile(destination)
    }

    func removeExportedFile(_ payload: TrackSharePayload) {
        let url = payload.fileURL
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PrivateMusicShare", isDirectory: true)
            .standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard url.isFileURL,
              parent.path.hasPrefix(exportRoot.path + "/") else {
            return
        }
        try? fileManager.removeItem(at: parent)
    }

    private var fileTooLargeError: APIError {
        APIError.server(
            code: 413,
            message: L10n.text("Файл больше 150 МБ.")
        )
    }

    private var directAudioUnavailableError: APIError {
        APIError.server(
            code: 415,
            message: L10n.text(
                "VK не предоставил прямой аудиофайл для этого трека."
            )
        )
    }

    private var directMP3UnavailableError: APIError {
        APIError.server(
            code: 415,
            message: L10n.text(
                "Этот трек нельзя экспортировать в MP3."
            )
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
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("PrivateMusicShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
            .appendingPathComponent(name)
            .appendingPathExtension(extensionName)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func fileExtension(
        response: HTTPURLResponse,
        sourceURL: URL
    ) throws -> String {
        switch response.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/flac": return "flac"
        default: break
        }
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "flac"].contains(sourceExtension) {
            return sourceExtension
        }
        throw directAudioUnavailableError
    }

    private func isLikelyMP3(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 3)) ?? Data()
        if prefix.starts(with: Data("ID3".utf8)) {
            return true
        }
        guard prefix.count >= 2 else { return false }
        return prefix[prefix.startIndex] == 0xFF
            && prefix[prefix.index(after: prefix.startIndex)] & 0xE0 == 0xE0
    }

    private func isHLSFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 16)) ?? Data()
        return String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("#EXTM3U") == true
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
    let onCompletion: () -> Void

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let activityItems: [Any]
        switch payload {
        case let .audioFile(fileURL):
            activityItems = [fileURL]
        }
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                onCompletion()
            }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
