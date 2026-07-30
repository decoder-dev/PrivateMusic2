import Foundation

struct OfflineTrackRecord: Codable, Identifiable, Equatable, Sendable {
    let track: Track
    let relativePath: String
    let storage: OfflineTrackStorage?
    let byteCount: Int64
    let downloadedAt: Date
    var lastPlayedAt: Date

    var id: String { track.id }

    var resolvedStorage: OfflineTrackStorage {
        storage ?? .directFile
    }
}

enum OfflineTrackStorage: String, Codable, Sendable {
    case directFile
    case hlsPackage
}

enum OfflineTrackState: Equatable {
    case remote
    case downloading
    case available
}

@MainActor
final class OfflineTrackStore: ObservableObject {
    static let maximumTrackSize: Int64 = 150_000_000
    static let maximumLibrarySize: Int64 = 5_000_000_000

    @Published private(set) var records: [String: OfflineTrackRecord] = [:]
    @Published private(set) var downloadingTrackIDs: Set<String> = []

    private let fileManager: FileManager
    private let rootURL: URL
    private let downloadService: TrackShareService
    private let hlsDownloadService: HLSOfflineDownloadService
    private var activeAccountID: Int?

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        downloadService: TrackShareService = TrackShareService(),
        hlsDownloadService: HLSOfflineDownloadService =
            .shared
    ) {
        self.fileManager = fileManager
        self.downloadService = downloadService
        self.hlsDownloadService = hlsDownloadService
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = (
                try? fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            ) ?? fileManager.temporaryDirectory
            self.rootURL = applicationSupport
                .appendingPathComponent("PrivateMusic", isDirectory: true)
                .appendingPathComponent("Offline", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
    }

    func configure(accountID: Int?) {
        guard activeAccountID != accountID else { return }
        activeAccountID = accountID
        downloadingTrackIDs.removeAll()
        records = loadManifest()
        reconcile()
    }

    func state(for track: Track) -> OfflineTrackState {
        if downloadingTrackIDs.contains(track.id) {
            return .downloading
        }
        return localURL(for: track) == nil ? .remote : .available
    }

    func contains(_ track: Track) -> Bool {
        localURL(for: track) != nil
    }

    func localURL(for track: Track) -> URL? {
        guard let record = records[track.id],
              let directory = accountDirectory else {
            return nil
        }
        let url = resolvedURL(for: record, accountDirectory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var downloadedTracks: [Track] {
        records.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.track)
    }

    var totalByteCount: Int64 {
        records.values.reduce(0) { $0 + $1.byteCount }
    }

    func download(
        _ track: Track,
        userAgent: String?
    ) async throws {
        guard let accountID = activeAccountID else {
            throw APIError.unauthorized
        }
        guard !downloadingTrackIDs.contains(track.id) else { return }
        if contains(track) { return }

        downloadingTrackIDs.insert(track.id)
        defer { downloadingTrackIDs.remove(track.id) }

        if isHLS(track.streamURL) {
            try await downloadHLS(
                track,
                accountID: accountID,
                userAgent: userAgent
            )
        } else {
            try await downloadDirectFile(
                track,
                accountID: accountID,
                userAgent: userAgent
            )
        }
    }

    private func downloadDirectFile(
        _ track: Track,
        accountID: Int,
        userAgent: String?
    ) async throws {
        let payload = try await downloadService.preparePayload(
            for: track,
            userAgent: userAgent
        )
        let temporaryURL = payload.fileURL
        defer { Task { await downloadService.removeExportedFile(payload) } }
        guard activeAccountID == accountID else {
            throw CancellationError()
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: temporaryURL.path
        )
        let byteCount =
            (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0,
              byteCount <= Self.maximumTrackSize else {
            throw offlineError("Файл слишком большой для офлайн-загрузки.")
        }
        guard totalByteCount + byteCount <= Self.maximumLibrarySize else {
            throw offlineError(
                "Для офлайн-музыки занято больше 5 ГБ. "
                    + "Удалите часть загрузок."
            )
        }
        try createProtectedDirectory(rootURL)
        try ensureFreeSpace(for: byteCount)

        guard let directory = accountDirectory else {
            throw APIError.unauthorized
        }
        let tracksDirectory = directory
            .appendingPathComponent("tracks", isDirectory: true)
        let stagingDirectory = directory
            .appendingPathComponent(".staging", isDirectory: true)
        try createProtectedDirectory(tracksDirectory)
        try createProtectedDirectory(stagingDirectory)

        let stagingURL = stagingDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(temporaryURL.pathExtension)
        try fileManager.copyItem(at: temporaryURL, to: stagingURL)

        let trackDirectory = tracksDirectory
            .appendingPathComponent(track.id, isDirectory: true)
        if fileManager.fileExists(atPath: trackDirectory.path) {
            try fileManager.removeItem(at: trackDirectory)
        }
        try createProtectedDirectory(trackDirectory)
        let destination = trackDirectory
            .appendingPathComponent("audio")
            .appendingPathExtension(temporaryURL.pathExtension)
        try fileManager.moveItem(at: stagingURL, to: destination)
        try setFileAttributes(destination)

        let storedTrack = Track(
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
        let relativePath = destination.path
            .replacingOccurrences(
                of: directory.path + "/",
                with: ""
            )
        let now = Date()
        records[track.id] = OfflineTrackRecord(
            track: storedTrack,
            relativePath: relativePath,
            storage: .directFile,
            byteCount: byteCount,
            downloadedAt: now,
            lastPlayedAt: now
        )
        try saveManifest()
    }

    private func downloadHLS(
        _ track: Track,
        accountID: Int,
        userAgent: String?
    ) async throws {
        try createProtectedDirectory(rootURL)
        let estimatedSize = min(
            Self.maximumTrackSize,
            max(20_000_000, Int64(track.duration * 40_000))
        )
        try ensureFreeSpace(for: estimatedSize)

        let location = try await hlsDownloadService.download(
            track: track,
            userAgent: userAgent
        )
        guard activeAccountID == accountID else {
            try? fileManager.removeItem(at: location)
            throw CancellationError()
        }

        let byteCount = allocatedSize(at: location)
        guard byteCount > 0,
              byteCount <= Self.maximumTrackSize else {
            try? fileManager.removeItem(at: location)
            throw offlineError("Файл слишком большой для офлайн-загрузки.")
        }
        guard totalByteCount + byteCount <= Self.maximumLibrarySize else {
            try? fileManager.removeItem(at: location)
            throw offlineError(
                "Для офлайн-музыки занято больше 5 ГБ. "
                    + "Удалите часть загрузок."
            )
        }
        let storedTrack = Track(
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
        let record = OfflineTrackRecord(
            track: storedTrack,
            relativePath: relativePathFromHome(for: location),
            storage: .hlsPackage,
            byteCount: byteCount,
            downloadedAt: Date(),
            lastPlayedAt: Date()
        )
        records[track.id] = record
        do {
            try saveManifest()
        } catch {
            records.removeValue(forKey: track.id)
            try? fileManager.removeItem(at: location)
            throw error
        }
    }

    func remove(_ track: Track) {
        guard let record = records.removeValue(forKey: track.id),
              let directory = accountDirectory else {
            return
        }
        let fileURL = resolvedURL(
            for: record,
            accountDirectory: directory
        )
        switch record.resolvedStorage {
        case .directFile:
            let trackDirectory = fileURL.deletingLastPathComponent()
            if trackDirectory.standardizedFileURL.path.hasPrefix(
                directory.standardizedFileURL.path + "/"
            ) {
                try? fileManager.removeItem(at: trackDirectory)
            }
        case .hlsPackage:
            if isInsideAppContainer(fileURL) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
        try? saveManifest()
    }

    func markPlayed(_ track: Track) {
        guard var record = records[track.id] else { return }
        record.lastPlayedAt = Date()
        records[track.id] = record
        try? saveManifest()
    }

    private var accountDirectory: URL? {
        guard let activeAccountID else { return nil }
        return rootURL
            .appendingPathComponent(String(activeAccountID), isDirectory: true)
    }

    private var manifestURL: URL? {
        accountDirectory?.appendingPathComponent("index.json")
    }

    private func loadManifest() -> [String: OfflineTrackRecord] {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let values = try? decoder.decode(
            [OfflineTrackRecord].self,
            from: data
        ) else { return [:] }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    private func saveManifest() throws {
        guard let directory = accountDirectory,
              let manifestURL else {
            throw APIError.unauthorized
        }
        try createProtectedDirectory(directory)
        let values = records.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(values)
        try data.write(to: manifestURL, options: .atomic)
        try setFileAttributes(manifestURL)
    }

    private func reconcile() {
        guard let directory = accountDirectory else { return }
        var reconciled = records
        for (id, record) in records {
            let url = resolvedURL(
                for: record,
                accountDirectory: directory
            )
            if !fileManager.fileExists(atPath: url.path) {
                reconciled.removeValue(forKey: id)
            }
        }
        records = reconciled
        if let staging = accountDirectory?
            .appendingPathComponent(".staging", isDirectory: true) {
            try? fileManager.removeItem(at: staging)
        }
        try? saveManifest()
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func setFileAttributes(_ url: URL) throws {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func ensureFreeSpace(for byteCount: Int64) throws {
        let values = try rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity < byteCount + 100_000_000 {
            throw offlineError("На устройстве недостаточно свободного места.")
        }
    }

    private func resolvedURL(
        for record: OfflineTrackRecord,
        accountDirectory: URL
    ) -> URL {
        switch record.resolvedStorage {
        case .directFile:
            return accountDirectory.appendingPathComponent(
                record.relativePath
            )
        case .hlsPackage:
            return homeDirectory.appendingPathComponent(
                record.relativePath
            )
        }
    }

    private var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private func relativePathFromHome(for url: URL) -> String {
        let homePath = homeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(homePath.count + 1))
    }

    private func isInsideAppContainer(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(
            homeDirectory.standardizedFileURL.path + "/"
        )
    }

    private func allocatedSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? 0
            )
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? 0
            )
        }
        return total
    }

    private func isHLS(_ url: URL?) -> Bool {
        url?.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame
    }

    private func offlineError(_ message: String) -> APIError {
        APIError.server(code: 507, message: L10n.text(message))
    }
}
