import Foundation
import UIKit

enum OfflinePlaylistDownloadState: String, Codable, Sendable {
    case idle
    case resolvingTracks
    case queued
    case downloading
    case available
    case partial
    case cancelled
    case failed
}

struct OfflinePlaylistRecord: Codable, Identifiable, Equatable, Sendable {
    var playlist: Playlist
    var tracks: [Track]
    var artworkRelativePath: String?
    var state: OfflinePlaylistDownloadState
    var completedCount: Int
    var failedCount: Int
    var processedCount: Int
    var errorMessage: String?
    var artworkError: String?
    var updatedAt: Date

    init(
        playlist: Playlist,
        tracks: [Track] = [],
        artworkRelativePath: String? = nil,
        state: OfflinePlaylistDownloadState,
        completedCount: Int = 0,
        failedCount: Int = 0,
        processedCount: Int = 0,
        errorMessage: String? = nil,
        artworkError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.playlist = playlist
        self.tracks = tracks
        self.artworkRelativePath = artworkRelativePath
        self.state = state
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.processedCount = processedCount
        self.errorMessage = errorMessage
        self.artworkError = artworkError
        self.updatedAt = updatedAt
    }

    var id: String {
        Self.identifier(for: playlist)
    }

    /// Exact denominator once the playlist has been resolved; the stored
    /// `playlist.count` is only an estimate while tracks are still being
    /// fetched.
    var totalCount: Int {
        tracks.isEmpty ? playlist.count : tracks.count
    }

    var progress: Double {
        switch state {
        case .resolvingTracks, .queued:
            return 0
        case .available:
            return 1
        default:
            guard totalCount > 0 else { return 0 }
            return min(1, Double(processedCount) / Double(totalCount))
        }
    }

    static func identifier(for playlist: Playlist) -> String {
        "\(playlist.ownerID)_\(playlist.id)"
    }

    enum CodingKeys: String, CodingKey {
        case playlist
        case tracks
        case artworkRelativePath
        case state
        case completedCount
        case failedCount
        case processedCount
        case errorMessage
        case artworkError
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlist = try container.decode(Playlist.self, forKey: .playlist)
        tracks = try container.decode([Track].self, forKey: .tracks)
        artworkRelativePath = try container.decodeIfPresent(
            String.self,
            forKey: .artworkRelativePath
        )
        state = try container.decode(
            OfflinePlaylistDownloadState.self,
            forKey: .state
        )
        completedCount = try container.decode(Int.self, forKey: .completedCount)
        failedCount = try container.decodeIfPresent(
            Int.self,
            forKey: .failedCount
        ) ?? 0
        processedCount = try container.decodeIfPresent(
            Int.self,
            forKey: .processedCount
        ) ?? completedCount + failedCount
        errorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .errorMessage
        )
        artworkError = try container.decodeIfPresent(
            String.self,
            forKey: .artworkError
        )
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playlist, forKey: .playlist)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(
            artworkRelativePath,
            forKey: .artworkRelativePath
        )
        try container.encode(state, forKey: .state)
        try container.encode(completedCount, forKey: .completedCount)
        try container.encode(failedCount, forKey: .failedCount)
        try container.encode(processedCount, forKey: .processedCount)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(artworkError, forKey: .artworkError)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// UI-facing status derived from a record's explicit state. Lives next to the
/// model so every screen (and tests) can render the same text and progress.
enum OfflinePlaylistStatus: Equatable, Sendable {
    case preparing
    case queued
    case downloading(processed: Int, total: Int, succeeded: Int, failed: Int)
    case completed(count: Int, total: Int)
    case partial(count: Int, total: Int)
    case failed(message: String?)
    case cancelled
    case idle

    var isActive: Bool {
        switch self {
        case .preparing, .queued, .downloading:
            return true
        default:
            return false
        }
    }

    var progress: Double? {
        switch self {
        case .downloading(let processed, let total, _, _):
            guard total > 0 else { return nil }
            return min(1, Double(processed) / Double(total))
        case .completed:
            return 1
        default:
            return nil
        }
    }

    var localizedText: String? {
        switch self {
        case .preparing:
            return L10n.text("Подготовка…")
        case .queued:
            return L10n.text("В очереди…")
        case .downloading(let processed, let total, let succeeded, let failed):
            return L10n.format(
                "Обработано %d из %d · Скачано %d · Ошибок %d",
                processed,
                total,
                succeeded,
                failed
            )
        case .completed:
            return nil
        case .partial(let count, let total):
            return L10n.format("Скачано %d из %d", count, total)
        case .failed(let message):
            return message ?? L10n.text("Не удалось скачать плейлист")
        case .cancelled:
            return L10n.text("Загрузка отменена")
        case .idle:
            return nil
        }
    }

    static func status(for record: OfflinePlaylistRecord) -> OfflinePlaylistStatus {
        switch record.state {
        case .idle, .resolvingTracks:
            return .preparing
        case .queued:
            return .queued
        case .downloading:
            return .downloading(
                processed: record.processedCount,
                total: record.totalCount,
                succeeded: record.completedCount,
                failed: record.failedCount
            )
        case .available:
            return .completed(
                count: record.completedCount,
                total: record.totalCount
            )
        case .partial:
            return .partial(
                count: record.completedCount,
                total: record.totalCount
            )
        case .failed:
            return .failed(message: record.errorMessage)
        case .cancelled:
            return .cancelled
        }
    }
}

@MainActor
final class OfflinePlaylistStore: ObservableObject {
    static let shared = OfflinePlaylistStore()
    static let maximumArtworkSize = 12 * 1_024 * 1_024

    typealias PageFetcher = @Sendable (Int) async throws -> MusicPage<Track>
    typealias TrackDownloader = @Sendable (Track) async throws -> Void

    private struct ActiveTask {
        let generation: UUID
        let task: Task<Void, Never>
    }

    @Published private(set) var records: [String: OfflinePlaylistRecord] = [:]

    private let fileManager: FileManager
    private let rootURL: URL
    private let artworkSession: URLSession
    private var activeAccountID: Int?
    private var activeTasks: [String: ActiveTask] = [:]
    private var isSaveScheduled = false
    private var hasPendingSave = false

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        artworkSession: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.artworkSession = artworkSession
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = (
                try? fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            ) ?? fileManager.temporaryDirectory
            self.rootURL = support
                .appendingPathComponent("PrivateMusic", isDirectory: true)
                .appendingPathComponent("OfflinePlaylists", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
    }

    func configure(accountID: Int?) {
        guard activeAccountID != accountID else { return }
        activeTasks.values.forEach { $0.task.cancel() }
        activeTasks.removeAll()
        activeAccountID = accountID
        records = loadManifest()
        reconcileFiles()
    }

    func record(for playlist: Playlist) -> OfflinePlaylistRecord? {
        records[OfflinePlaylistRecord.identifier(for: playlist)]
    }

    func localArtworkURL(for playlist: Playlist) -> URL? {
        guard let directory = accountDirectory,
              let relativePath = record(for: playlist)?.artworkRelativePath else {
            return nil
        }
        let url = directory.appendingPathComponent(relativePath)
        guard isInside(url, parent: directory),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Total size of locally stored playlist artwork (used by storage usage).
    var artworkByteCount: Int64 {
        guard let directory = accountDirectory else { return 0 }
        let artworkDirectory = directory
            .appendingPathComponent("artwork", isDirectory: true)
        guard fileManager.fileExists(atPath: artworkDirectory.path) else {
            return 0
        }
        return allocatedSize(at: artworkDirectory)
    }

    /// Publishes the artwork folder size to the thread-safe snapshot read by
    /// the (non-isolated) track store for the storage usage screen.
    private func refreshArtworkBytesSnapshot() {
        PlaylistArtworkBytesBox.shared.update(artworkByteCount)
    }

    @discardableResult
    func startDownload(
        playlist: Playlist,
        fetchPage: @escaping PageFetcher,
        downloadTrack: @escaping TrackDownloader
    ) -> Task<Void, Never> {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        if let existing = activeTasks[identifier] {
            return existing.task
        }
        guard let accountID = activeAccountID else {
            return Task {}
        }

        var record = records[identifier] ?? OfflinePlaylistRecord(
            playlist: playlist,
            state: .resolvingTracks
        )
        // Always refresh metadata with the current playlist (defect 1).
        record.playlist = playlist
        record.state = .resolvingTracks
        record.completedCount = 0
        record.failedCount = 0
        record.processedCount = 0
        record.errorMessage = nil
        record.updatedAt = Date()
        records[identifier] = record
        requestSave()

        let generation = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(
                identifier: identifier,
                accountID: accountID,
                generation: generation,
                fetchPage: fetchPage,
                downloadTrack: downloadTrack
            )
        }
        activeTasks[identifier] = ActiveTask(generation: generation, task: task)
        return task
    }

    func cancelDownload(for playlist: Playlist) {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        guard let active = activeTasks[identifier] else { return }
        active.task.cancel()
        // Remove immediately so a restart is not blocked by the dying task.
        activeTasks.removeValue(forKey: identifier)
        guard var record = records[identifier],
              record.state == .resolvingTracks
                || record.state == .queued
                || record.state == .downloading else {
            return
        }
        record.state = .cancelled
        record.updatedAt = Date()
        records[identifier] = record
        requestSave()
    }

    func remove(_ playlist: Playlist) {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        activeTasks.removeValue(forKey: identifier)?.task.cancel()
        guard let record = records.removeValue(forKey: identifier) else { return }
        if let relativePath = record.artworkRelativePath,
           let directory = accountDirectory {
            let url = directory.appendingPathComponent(relativePath)
            if isInside(url, parent: directory) {
                try? fileManager.removeItem(at: url)
            }
        }
        requestSave()
        refreshArtworkBytesSnapshot()
    }

    func removeAll() {
        activeTasks.values.forEach { $0.task.cancel() }
        activeTasks.removeAll()
        guard let directory = accountDirectory else {
            records.removeAll()
            requestSave()
            return
        }
        let artworkDir = directory
            .appendingPathComponent("artwork", isDirectory: true)
        if fileManager.fileExists(atPath: artworkDir.path) {
            try? fileManager.removeItem(at: artworkDir)
        }
        records.removeAll()
        requestSave()
        refreshArtworkBytesSnapshot()
    }

    func waitForDownload(of playlist: Playlist) async {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        await activeTasks[identifier]?.task.value
    }

    /// Recomputed playlist states from the real track files after local
    /// deletions: an `available` record whose files disappeared becomes
    /// `partial` or `failed`, and an empty record is never left `available`.
    func reconcileDownloads(with offlineStore: OfflineTrackStore) {
        var didChange = false
        for (id, var record) in records {
            guard record.state != .resolvingTracks,
                  record.state != .queued,
                  record.state != .downloading else {
                continue
            }
            let localCount = record.tracks
                .filter { offlineStore.contains($0) }
                .count
            var recordChanged = false
            switch record.state {
            case .available:
                if localCount == 0 {
                    record.state = .failed
                    record.errorMessage = L10n.text(
                        "Скачанные треки удалены. Скачайте плейлист заново."
                    )
                    recordChanged = true
                } else if localCount < record.tracks.count {
                    record.state = .partial
                    recordChanged = true
                }
            case .partial:
                if localCount == 0 {
                    record.state = .failed
                    record.errorMessage = L10n.text(
                        "Скачанные треки удалены. Скачайте плейлист заново."
                    )
                    recordChanged = true
                }
            default:
                break
            }
            if recordChanged {
                record.updatedAt = Date()
                records[id] = record
                didChange = true
            }
        }
        if didChange {
            requestSave()
        }
    }

    /// Throttled manifest persistence (defect 21): progress updates never
    /// write the full manifest per track on the main thread.
    func flushPendingSave() async throws {
        hasPendingSave = false
        isSaveScheduled = false
        try await persistToDisk()
    }

    private func runDownload(
        identifier: String,
        accountID: Int?,
        generation: UUID,
        fetchPage: @escaping PageFetcher,
        downloadTrack: @escaping TrackDownloader
    ) async {
        defer {
            if isCurrentTask(identifier: identifier, generation: generation) {
                activeTasks.removeValue(forKey: identifier)
            }
        }
        guard accountID != nil, accountID == activeAccountID,
              var record = records[identifier] else {
            return
        }

        do {
            record.state = .resolvingTracks
            record.errorMessage = nil
            record.updatedAt = Date()
            records[identifier] = record
            requestSave()

            let tracks = try await fetchAllPages(fetchPage)
            try Task.checkCancellation()
            guard isCurrentTask(identifier: identifier, generation: generation),
                  accountID == activeAccountID else {
                throw CancellationError()
            }

            // Artwork is best effort and runs before the empty check so a
            // record with no fetchable tracks still keeps its cover.
            if record.artworkRelativePath == nil {
                do {
                    let path = try await downloadArtwork(
                        from: record.playlist.artworkURL,
                        identifier: identifier
                    )
                    guard isCurrentTask(
                        identifier: identifier,
                        generation: generation
                    ), accountID == activeAccountID else {
                        throw CancellationError()
                    }
                    record.artworkRelativePath = path
                    record.artworkError = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Best effort: artwork must never fail the batch.
                    record.artworkError = error.localizedDescription
                }
                records[identifier] = record
                requestSave()
                refreshArtworkBytesSnapshot()
            }

            if tracks.isEmpty {
                if record.playlist.count == 0 {
                    // Never leave an empty permanent record behind.
                    records.removeValue(forKey: identifier)
                    requestSave()
                } else {
                    record.state = .failed
                    record.errorMessage = L10n.text(
                        "Не удалось получить треки плейлиста"
                    )
                    record.updatedAt = Date()
                    records[identifier] = record
                    requestSave()
                    DownloadNotifications.notifyDownloadError(
                        title: record.playlist.title
                    )
                }
                await flushAfterTerminalState()
                return
            }

            // The resolved list becomes the exact total; the stored playlist
            // keeps its metadata refreshed.
            let storedTracks = tracks.map(Self.storableTrack)
            record.tracks = storedTracks
            if record.playlist.count != storedTracks.count {
                record.playlist = record.playlist
                    .updatingCount(storedTracks.count)
            }
            record.state = .downloading
            record.updatedAt = Date()
            records[identifier] = record
            requestSave()

            let counts = await downloadTracks(
                storedTracks,
                downloadTrack: downloadTrack,
                identifier: identifier,
                generation: generation
            )
            try Task.checkCancellation()
            guard isCurrentTask(identifier: identifier, generation: generation),
                  accountID == activeAccountID,
                  var finalRecord = records[identifier] else {
                throw CancellationError()
            }
            finalRecord.completedCount = counts.completed
            finalRecord.failedCount = counts.failed
            finalRecord.processedCount = counts.completed + counts.failed
            let name = finalRecord.playlist.title
            if storedTracks.isEmpty || counts.failed == 0 {
                finalRecord.state = .available
                DownloadNotifications.notifyDownloadComplete(title: name)
            } else if counts.completed > 0 {
                finalRecord.state = .partial
                finalRecord.errorMessage = L10n.format(
                    "Не удалось скачать %d из %d треков",
                    counts.failed,
                    storedTracks.count
                )
                let completedSubtitle = L10n.format(
                    "Скачано %d из %d",
                    counts.completed,
                    storedTracks.count
                )
                DownloadNotifications.notifyDownloadComplete(
                    title: "\(name) · \(completedSubtitle)"
                )
            } else {
                finalRecord.state = .failed
                finalRecord.errorMessage = L10n.text(
                    "Не удалось скачать плейлист"
                )
                DownloadNotifications.notifyDownloadError(title: name)
            }
            finalRecord.updatedAt = Date()
            records[identifier] = finalRecord
            await flushAfterTerminalState()
        } catch is CancellationError {
            guard isCurrentTask(identifier: identifier, generation: generation),
                  accountID == activeAccountID,
                  var cancelled = records[identifier] else {
                return
            }
            cancelled.state = .cancelled
            cancelled.updatedAt = Date()
            records[identifier] = cancelled
            await flushAfterTerminalState()
        } catch {
            guard isCurrentTask(identifier: identifier, generation: generation),
                  accountID == activeAccountID,
                  var failed = records[identifier] else {
                return
            }
            failed.state = failed.completedCount > 0 ? .partial : .failed
            failed.errorMessage = error.localizedDescription
            failed.updatedAt = Date()
            records[identifier] = failed
            await flushAfterTerminalState()
        }
    }

    private func flushAfterTerminalState() async {
        do {
            try await flushPendingSave()
        } catch {
            // Persistence failure is non-fatal for the download itself; the
            // in-memory state stays authoritative and reconciliation handles
            // any missing manifest on the next launch.
        }
    }

    private func isCurrentTask(identifier: String, generation: UUID) -> Bool {
        activeTasks[identifier]?.generation == generation
    }

    private func fetchAllPages(
        _ fetchPage: PageFetcher
    ) async throws -> [Track] {
        var offset = 0
        var known = Set<String>()
        var result: [Track] = []
        var visitedOffsets = Set<Int>()
        var pageCount = 0
        let maximumPageCount = 100

        while true {
            try Task.checkCancellation()
            guard !visitedOffsets.contains(offset) else { break }
            visitedOffsets.insert(offset)
            pageCount += 1
            guard pageCount <= maximumPageCount else { break }

            let page = try await fetchPage(offset)
            try Task.checkCancellation()

            let before = result.count
            result.append(contentsOf: page.items.filter {
                known.insert($0.id).inserted
            })
            let added = result.count - before
            if added == 0 { break }

            guard let next = page.nextOffset,
                  next > offset,
                  !visitedOffsets.contains(next) else {
                return result
            }
            if page.totalCount > 0, known.count >= page.totalCount {
                return result
            }
            offset = next
        }
        return result
    }

    private func downloadTracks(
        _ tracks: [Track],
        downloadTrack: @escaping TrackDownloader,
        identifier: String,
        generation: UUID
    ) async -> (completed: Int, failed: Int) {
        await withTaskGroup(of: Bool.self) { group in
            var completed = 0
            var failed = 0

            for track in tracks {
                group.addTask {
                    guard !Task.isCancelled else { return false }
                    do {
                        try await downloadTrack(track)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            while let success = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if success {
                    completed += 1
                } else {
                    failed += 1
                }
                updateProgress(
                    identifier: identifier,
                    generation: generation,
                    completed: completed,
                    failed: failed
                )
            }
            return (completed, failed)
        }
    }

    private func updateProgress(
        identifier: String,
        generation: UUID,
        completed: Int,
        failed: Int
    ) {
        guard isCurrentTask(identifier: identifier, generation: generation),
              var record = records[identifier] else {
            return
        }
        record.completedCount = completed
        record.failedCount = failed
        record.processedCount = completed + failed
        record.updatedAt = Date()
        records[identifier] = record
        requestSave()
    }

    private func downloadArtwork(
        from remoteURL: URL?,
        identifier: String
    ) async throws -> String? {
        guard let remoteURL else { return nil }
        guard remoteURL.scheme?.lowercased() == "https",
              remoteURL.host != nil else {
            return nil
        }
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await artworkSession.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 0,
              data.count <= Self.maximumArtworkSize,
              http.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("image/") == true,
              UIImage(data: data) != nil,
              let directory = accountDirectory else {
            return nil
        }

        let artworkDirectory = directory
            .appendingPathComponent("artwork", isDirectory: true)
        try createDirectory(artworkDirectory)
        let safeName = identifier.replacingOccurrences(of: "/", with: "_")
        let destination = artworkDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("img")
        try data.write(to: destination, options: .atomic)
        protect(destination)
        return destination.path.replacingOccurrences(
            of: directory.path + "/",
            with: ""
        )
    }

    private static func storableTrack(_ track: Track) -> Track {
        Track(
            trackID: track.trackID,
            ownerID: track.ownerID,
            title: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle,
            duration: track.duration,
            streamURL: nil,
            artworkURL: track.artworkURL,
            accessKey: track.accessKey,
            lyricsID: track.lyricsID
        )
    }

    private var accountDirectory: URL? {
        guard let activeAccountID else { return nil }
        return rootURL.appendingPathComponent(
            String(activeAccountID),
            isDirectory: true
        )
    }

    private var manifestURL: URL? {
        accountDirectory?.appendingPathComponent("index.json")
    }

    private func loadManifest() -> [String: OfflinePlaylistRecord] {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(
            [OfflinePlaylistRecord].self,
            from: data
        ) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persistToDisk() async throws {
        guard let directory = accountDirectory,
              let manifestURL else {
            throw APIError.unauthorized
        }
        try createDirectory(directory)
        let values = records.values.sorted { $0.id < $1.id }
        let writeURL = manifestURL
        let data = try await Task.detached(priority: .utility) { () -> Data in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(values)
        }.value
        try await Task.detached(priority: .utility) {
            try data.write(to: writeURL, options: .atomic)
        }.value
        protect(writeURL)
    }

    private func requestSave() {
        hasPendingSave = true
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.isSaveScheduled = false
            guard self.hasPendingSave else { return }
            self.hasPendingSave = false
            do {
                try await self.persistToDisk()
            } catch {
                // The next request or terminal flush retries the write.
            }
            if self.hasPendingSave {
                self.requestSave()
            }
        }
    }

    private func reconcileFiles() {
        guard let directory = accountDirectory else { return }
        var result = records
        for (id, var record) in records {
            if let relative = record.artworkRelativePath {
                let url = directory.appendingPathComponent(relative)
                if !isInside(url, parent: directory)
                    || !fileManager.fileExists(atPath: url.path) {
                    record.artworkRelativePath = nil
                    result[id] = record
                }
            }
            // Records that look active must never survive a restart without a
            // real running Task (requirement C).
            if record.state == .resolvingTracks
                || record.state == .queued
                || record.state == .downloading {
                record.state = record.completedCount > 0 ? .partial : .cancelled
                record.errorMessage = L10n.text("Загрузка прервана")
                result[id] = record
            }
        }
        records = result
        refreshArtworkBytesSnapshot()
        try? saveManifestSync()
    }

    private func saveManifestSync() throws {
        guard let directory = accountDirectory,
              let manifestURL else {
            return
        }
        try createDirectory(directory)
        let values = records.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(values)
        try data.write(to: manifestURL, options: .atomic)
        protect(manifestURL)
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        protect(url)
    }

    private func protect(_ url: URL) {
        try? fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: url.path
        )
    }

    private func isInside(_ url: URL, parent: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(
            parent.standardizedFileURL.path + "/"
        )
    }

    private func allocatedSize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: []
        ) else {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]
            )
            return Int64(values?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Thread-safe cache of the playlist store's artwork folder size, read from
/// the non-isolated track store for the storage usage screen.
final class PlaylistArtworkBytesBox: @unchecked Sendable {
    static let shared = PlaylistArtworkBytesBox()

    private var value: Int64 = 0
    private let lock = NSLock()

    func update(_ newValue: Int64) {
        lock.withLock { value = newValue }
    }

    func current() -> Int64 {
        lock.withLock { value }
    }
}
