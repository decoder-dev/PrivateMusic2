import AVFoundation
import Foundation

/// Downloads HLS assets using the system-managed offline media container.
///
/// AVFoundation owns the resulting package. It must not be moved or inspected;
/// callers persist its path relative to the app container and play that URL.
final class HLSOfflineDownloadService: NSObject,
    AVAssetDownloadDelegate,
    @unchecked Sendable {
    static let shared = HLSOfflineDownloadService()
    static let backgroundSessionIdentifier =
        "com.dec.privatemusic2.offline-hls"

    private final class ActiveDownload {
        let continuation: CheckedContinuation<URL, Error>
        var location: URL?

        init(continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var activeDownloads: [Int: ActiveDownload] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private var session: AVAssetDownloadURLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "PrivateMusic.HLSOfflineDownload"
        delegateQueue.maxConcurrentOperationCount = 1
        session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: delegateQueue
        )
    }

    func download(
        track: Track,
        userAgent: String?
    ) async throws -> URL {
        guard let streamURL = track.streamURL,
              streamURL.pathExtension
                .caseInsensitiveCompare("m3u8") == .orderedSame else {
            throw HLSOfflineDownloadError.invalidManifest
        }

        var headers = [
            "Referer": "https://vk.com/",
            "Origin": "https://vk.com"
        ]
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        let asset = AVURLAsset(
            url: streamURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard let task = session.makeAssetDownloadTask(
                    asset: asset,
                    assetTitle: "\(track.artist) — \(track.title)",
                    assetArtworkData: nil,
                    options: nil
                ) else {
                    continuation.resume(
                        throwing: HLSOfflineDownloadError.cannotCreateTask
                    )
                    return
                }

                task.taskDescription = track.id
                synchronized {
                    activeDownloads[task.taskIdentifier] = ActiveDownload(
                        continuation: continuation
                    )
                }
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            session.getAllTasks { tasks in
                tasks
                    .filter { $0.taskDescription == track.id }
                    .forEach { $0.cancel() }
            }
        }
    }

    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        synchronized {
            backgroundCompletionHandler = completionHandler
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let recognized = synchronized {
            guard let active =
                    activeDownloads[assetDownloadTask.taskIdentifier] else {
                return false
            }
            active.location = location
            return true
        }
        if !recognized {
            try? FileManager.default.removeItem(at: location)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let active = synchronized {
            activeDownloads.removeValue(forKey: task.taskIdentifier)
        }
        guard let active else { return }

        if let error {
            if let location = active.location {
                try? FileManager.default.removeItem(at: location)
            }
            active.continuation.resume(throwing: error)
            return
        }
        guard let location = active.location else {
            active.continuation.resume(
                throwing: HLSOfflineDownloadError.missingDownloadedAsset
            )
            return
        }
        active.continuation.resume(returning: location)
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        let completion = synchronized {
            let value = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return value
        }
        guard let completion else { return }
        DispatchQueue.main.async {
            completion()
        }
    }

    private func synchronized<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum HLSOfflineDownloadError: LocalizedError {
    case invalidManifest
    case cannotCreateTask
    case missingDownloadedAsset

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return L10n.text("VK не предоставил HLS-поток для загрузки.")
        case .cannotCreateTask:
            return L10n.text("Не удалось начать загрузку HLS.")
        case .missingDownloadedAsset:
            return L10n.text("Системный загрузчик не сохранил аудио.")
        }
    }
}
