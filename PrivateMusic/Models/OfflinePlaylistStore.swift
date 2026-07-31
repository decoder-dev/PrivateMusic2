import Foundation
import UIKit

enum OfflinePlaylistDownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case available
    case partial
    case cancelled
    case failed
}

struct OfflinePlaylistRecord: Codable, Identifiable, Equatable, Sendable {
    let playlist: Playlist
    var tracks: [Track]
    var artworkRelativePath: String?
    var state: OfflinePlaylistDownloadState
    var completedCount: Int
    var failedCount: Int
    var updatedAt: Date

    var id: String {
        Self.identifier(for: playlist)
    }

    var totalCount: Int {
        tracks.count
    }

    var progress: Double {
        guard totalCount > 0 else {
            return state == .available ? 1 : 0
        }
        return min(1, Double(completedCount + failedCount) / Double(totalCount))
    }

    static func identifier(for playlist: Playlist) -> String {
        "\(playlist.ownerID)_\(playlist.id)"
    }
}

@MainActor
final class OfflinePlaylistStore: ObservableObject {
    static let shared = OfflinePlaylistStore()
    static let maximumArtworkSize = 12 * 1_024 * 1_024
    static let maximumConcurrentDownloads = 3

    typealias PageFetcher = @Sendable (Int) async throws -> MusicPage<Track>
    typealias TrackDownloader = @Sendable (Track) async throws -> Void

    @Published private(set) var records: [String: OfflinePlaylistRecord] = [:]

    private let fileManager: FileManager
    private let rootURL: URL
    private let artworkSession: URLSession
    private var activeAccountID: Int?
    private var activeTasks: [String: Task<Void, Never>] = [:]

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
        activeTasks.values.forEach { $0.cancel() }
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

    @discardableResult
    func startDownload(
        playlist: Playlist,
        fetchPage: @escaping PageFetcher,
        downloadTrack: @escaping TrackDownloader
    ) -> Task<Void, Never> {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        if let existing = activeTasks[identifier] {
            return existing
        }

        var record = records[identifier] ?? OfflinePlaylistRecord(
            playlist: playlist,
            tracks: [],
            artworkRelativePath: nil,
            state: .queued,
            completedCount: 0,
            failedCount: 0,
            updatedAt: Date()
        )
        record.state = .queued
        record.updatedAt = Date()
        records[identifier] = record
        try? saveManifest()

        let accountID = activeAccountID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(
                identifier: identifier,
                accountID: accountID,
                fetchPage: fetchPage,
                downloadTrack: downloadTrack
            )
        }
        activeTasks[identifier] = task
        return task
    }

    func cancelDownload(for playlist: Playlist) {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        activeTasks[identifier]?.cancel()
        guard var record = records[identifier],
              record.state == .queued || record.state == .downloading else {
            return
        }
        record.state = .cancelled
        record.updatedAt = Date()
        records[identifier] = record
        try? saveManifest()
    }

    func remove(_ playlist: Playlist) {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        activeTasks.removeValue(forKey: identifier)?.cancel()
        guard let record = records.removeValue(forKey: identifier) else { return }
        if let relativePath = record.artworkRelativePath,
           let directory = accountDirectory {
            let url = directory.appendingPathComponent(relativePath)
            if isInside(url, parent: directory) {
                try? fileManager.removeItem(at: url)
            }
        }
        try? saveManifest()
    }

    func removeAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        guard let directory = accountDirectory else {
            records.removeAll()
            try? saveManifest()
            return
        }
        if let artworkDir = directory
            .appendingPathComponent("artwork", isDirectory: true)
            , fileManager.fileExists(atPath: artworkDir.path) {
            try? fileManager.removeItem(at: artworkDir)
        }
        records.removeAll()
        try? saveManifest()
    }

    func waitForDownload(of playlist: Playlist) async {
        let identifier = OfflinePlaylistRecord.identifier(for: playlist)
        await activeTasks[identifier]?.value
    }

    private func runDownload(
        identifier: String,
        accountID: Int?,
        fetchPage: @escaping PageFetcher,
        downloadTrack: @escaping TrackDownloader
    ) async {
        defer { activeTasks.removeValue(forKey: identifier) }
        guard accountID != nil, accountID == activeAccountID,
              var record = records[identifier] else {
            return
        }

        do {
            record.state = .downloading
            record.completedCount = 0
            record.failedCount = 0
            record.updatedAt = Date()
            records[identifier] = record
            try saveManifest()

            let tracks = try await fetchAllPages(fetchPage)
            try Task.checkCancellation()
            guard accountID == activeAccountID else {
                throw CancellationError()
            }

            record.tracks = tracks.map(Self.storableTrack)
            record.updatedAt = Date()
            records[identifier] = record
            try saveManifest()

            if record.artworkRelativePath == nil {
                record.artworkRelativePath = try await downloadArtwork(
                    from: record.playlist.artworkURL,
                    identifier: identifier
                )
                records[identifier] = record
                try saveManifest()
            }

            let counts = await downloadTracks(
                tracks,
                downloadTrack: downloadTrack,
                progress: { [weak self] completed, failed in
                    guard let self else { return }
                    self.updateProgress(
                        identifier: identifier,
                        completed: completed,
                        failed: failed
                    )
                }
            )
            try Task.checkCancellation()
            guard accountID == activeAccountID,
                  var finalRecord = records[identifier] else {
                throw CancellationError()
            }
            finalRecord.completedCount = counts.completed
            finalRecord.failedCount = counts.failed
            if tracks.isEmpty || counts.failed == 0 {
                finalRecord.state = .available
            } else if counts.completed > 0 {
                finalRecord.state = .partial
            } else {
                finalRecord.state = .failed
            }
            finalRecord.updatedAt = Date()
            records[identifier] = finalRecord
            try saveManifest()
        } catch is CancellationError {
            if var cancelled = records[identifier],
               accountID == activeAccountID {
                cancelled.state = .cancelled
                cancelled.updatedAt = Date()
                records[identifier] = cancelled
                try? saveManifest()
            }
        } catch {
            if var failed = records[identifier],
               accountID == activeAccountID {
                failed.state = failed.completedCount > 0 ? .partial : .failed
                failed.updatedAt = Date()
                records[identifier] = failed
                try? saveManifest()
            }
        }
    }

    private func fetchAllPages(
        _ fetchPage: PageFetcher
    ) async throws -> [Track] {
        var offset = 0
        var known = Set<String>()
        var result: [Track] = []
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(offset)
            result.append(contentsOf: page.items.filter {
                known.insert($0.id).inserted
            })
            guard let next = page.nextOffset,
                  next > offset else {
                return result
            }
            offset = next
        }
    }

    private func downloadTracks(
        _ tracks: [Track],
        downloadTrack: @escaping TrackDownloader,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async -> (completed: Int, failed: Int) {
        await withTaskGroup(of: Bool.self) { group in
            var iterator = tracks.makeIterator()
            var completed = 0
            var failed = 0

            for _ in 0..<min(Self.maximumConcurrentDownloads, tracks.count) {
                if let track = iterator.next() {
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
                await progress(completed, failed)
                if let track = iterator.next() {
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
            }
            return (completed, failed)
        }
    }

    private func updateProgress(
        identifier: String,
        completed: Int,
        failed: Int
    ) {
        guard var record = records[identifier] else { return }
        record.completedCount = completed
        record.failedCount = failed
        record.updatedAt = Date()
        records[identifier] = record
        try? saveManifest()
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

    private func saveManifest() throws {
        guard let directory = accountDirectory,
              let manifestURL else {
            return
        }
        try createDirectory(directory)
        let values = records.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(values).write(to: manifestURL, options: .atomic)
        protect(manifestURL)
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
            if record.state == .queued || record.state == .downloading {
                record.state = record.completedCount > 0 ? .partial : .cancelled
                result[id] = record
            }
        }
        records = result
        try? saveManifest()
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
}
