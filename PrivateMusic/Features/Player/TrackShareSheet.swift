import SwiftUI
import UIKit
import AVFoundation

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

    func prepareFile(
        for track: Track,
        userAgent: String?
    ) async throws -> URL {
        guard let streamURL = track.streamURL else {
            throw APIError.invalidRequest
        }
        let headers = requestHeaders(userAgent: userAgent)
        if streamURL.pathExtension.lowercased() == "m3u8" {
            return try await exportHLS(
                track: track,
                streamURL: streamURL,
                headers: headers
            )
        }
        var request = URLRequest(url: streamURL)
        request.timeoutInterval = 60
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        if http.expectedContentLength > 150_000_000 {
            throw APIError.server(
                code: 413,
                message: L10n.text("Файл больше 150 МБ.")
            )
        }
        let mime = http.mimeType?.lowercased() ?? ""
        if mime.contains("mpegurl") || mime.contains("m3u") {
            return try await exportHLS(
                track: track,
                streamURL: streamURL,
                headers: headers
            )
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporaryURL.path
        )
        let size = attributes[.size] as? NSNumber
        guard size?.int64Value ?? 0 <= 150_000_000 else {
            throw APIError.server(
                code: 413,
                message: L10n.text("Файл больше 150 МБ.")
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

    private func exportHLS(
        track: Track,
        streamURL: URL,
        headers: [String: String]
    ) async throws -> URL {
        let destination = exportDestination(for: track, extensionName: "m4a")
        let asset = AVURLAsset(
            url: streamURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw APIError.server(
                code: 415,
                message: L10n.text("Не удалось подготовить аудиопоток.")
            )
        }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(
                            throwing: exporter.error
                                ?? APIError.server(
                                    code: 415,
                                    message: L10n.text(
                                        "Не удалось собрать аудиофайл."
                                    )
                                )
                        )
                    }
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }

        guard try fileSize(at: destination) <= 150_000_000 else {
            try? FileManager.default.removeItem(at: destination)
            throw APIError.server(
                code: 413,
                message: L10n.text("Файл больше 150 МБ.")
            )
        }
        return destination
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
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
            .appendingPathExtension(extensionName)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
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
