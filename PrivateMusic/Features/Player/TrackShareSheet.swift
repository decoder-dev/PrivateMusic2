import SwiftUI
import UIKit
import AVFoundation
import LinkPresentation
import UniformTypeIdentifiers

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
        if isHLS(streamURL) {
            return try await exportM4A(
                from: streamURL,
                track: track,
                userAgent: userAgent
            )
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
            guard isLikelyMP3(at: temporaryURL) else {
                throw directMP3UnavailableError
            }
        }

        let destination = exportDestination(
            for: track,
            extensionName: requiresMP3
                ? "mp3"
                : try fileExtension(
                    response: http,
                    sourceURL: streamURL,
                    downloadedURL: temporaryURL
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
    ) async throws -> TrackSharePayload {
        guard sourceURL.isFileURL,
              fileManager.fileExists(atPath: sourceURL.path) else {
            throw directAudioUnavailableError
        }
        if sourceURL.hasDirectoryPath
            || sourceURL.pathExtension.lowercased() == "movpkg" {
            guard !requiresMP3 else {
                throw directMP3UnavailableError
            }
            return try await exportM4A(
                from: sourceURL,
                track: track,
                userAgent: nil
            )
        }
        if requiresMP3 {
            guard isLikelyMP3(at: sourceURL) else {
                throw directMP3UnavailableError
            }
        }
        let extensionName: String
        if isLikelyMP3(at: sourceURL) {
            extensionName = "mp3"
        } else if isLikelyM4A(at: sourceURL) {
            extensionName = "m4a"
        } else {
            extensionName = sourceURL.pathExtension.lowercased()
        }
        let destination = exportDestination(
            for: track,
            extensionName: extensionName.isEmpty ? "m4a" : extensionName
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
        sourceURL: URL,
        downloadedURL: URL
    ) throws -> String {
        if isLikelyMP3(at: downloadedURL) {
            return "mp3"
        }
        if isLikelyM4A(at: downloadedURL) {
            return "m4a"
        }
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

    private func exportM4A(
        from sourceURL: URL,
        track: Track,
        userAgent: String?
    ) async throws -> TrackSharePayload {
        let asset: AVURLAsset
        if sourceURL.isFileURL {
            asset = AVURLAsset(url: sourceURL)
        } else {
            asset = AVURLAsset(
                url: sourceURL,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey":
                        requestHeaders(userAgent: userAgent)
                ]
            )
        }
        let isExportable = try await asset.load(.isExportable)
        guard isExportable,
              let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
              ) else {
            throw audioExportUnavailableError
        }
        let destination = exportDestination(
            for: track,
            extensionName: "m4a"
        )
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false
        let fallbackError = audioExportUnavailableError
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: exporter.error
                                ?? fallbackError
                        )
                    }
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }
        guard isLikelyM4A(at: destination),
              (try? fileSize(at: destination)) ?? 0 > 0 else {
            try? fileManager.removeItem(at: destination)
            throw audioExportUnavailableError
        }
        return .audioFile(destination)
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

    private func isLikelyM4A(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 12)) ?? Data()
        guard prefix.count >= 12 else { return false }
        let typeData = prefix.subdata(in: 4..<8)
        return String(data: typeData, encoding: .ascii) == "ftyp"
    }

    private var audioExportUnavailableError: APIError {
        APIError.server(
            code: 415,
            message: L10n.text(
                "Этот поток нельзя экспортировать в аудиофайл."
            )
        )
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
            activityItems = [
                AudioFileActivityItemSource(fileURL: fileURL)
            ]
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

private final class AudioFileActivityItemSource:
    NSObject,
    UIActivityItemSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        contentType.identifier
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = fileURL.deletingPathExtension().lastPathComponent
        metadata.originalURL = fileURL
        metadata.url = fileURL
        return metadata
    }

    private var contentType: UTType {
        switch fileURL.pathExtension.lowercased() {
        case "mp3":
            return .mp3
        case "m4a":
            return .mpeg4Audio
        case "aac":
            return .mpeg4Audio
        case "wav":
            return .wav
        default:
            return .audio
        }
    }
}
