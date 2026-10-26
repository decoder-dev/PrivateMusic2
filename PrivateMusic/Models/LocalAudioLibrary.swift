import Foundation
import Observation
import AVFoundation
import CryptoKit
import ImageIO

/// Local identities never share the VK owner/audio namespace. Paths are rebuilt
/// from app-owned UUID filenames, never from serialized source URLs.
enum LocalAudioPaths {
    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("LocalAudio", isDirectory: true)
    }
    static func artworkURL(for id: UUID, in directory: URL = LocalAudioPaths.directory) -> URL {
        directory.appendingPathComponent(id.uuidString + ".jpg")
    }
}

struct LocalAudioEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double
    let digest: String
    let hasArtwork: Bool
    let importedAt: Date

    func track(in directory: URL) -> Track {
        Track(trackID: 0, ownerID: 0, title: title, artist: artist, albumTitle: album,
              duration: duration, streamURL: nil,
              artworkURL: hasArtwork ? LocalAudioPaths.artworkURL(for: id, in: directory) : nil,
              localFileID: id)
    }

    var hasSafeFilename: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return LocalAudioImportPolicy.extensions.contains(ext) && filename == id.uuidString + "." + ext
    }
}

enum LocalAudioImportPolicy {
    static let maximumBytes = 150_000_000
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac"]
}

private enum LocalAudioError: LocalizedError {
    case unsupported, invalidSize, unplayable
    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.text("local_audio.unsupported")
        case .invalidSize: L10n.text("local_audio.invalid_size")
        case .unplayable: L10n.text("local_audio.unplayable")
        }
    }
}

@MainActor @Observable
final class LocalAudioLibrary {
    private(set) var entries: [LocalAudioEntry] = []
    private(set) var isImporting = false
    private(set) var importedCount = 0
    var errorMessage: String?
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let importer = LocalAudioImporter()
    @ObservationIgnored private var storageFailure: Error?

    init(directory: URL = LocalAudioPaths.directory) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let saved = try JSONDecoder().decode([LocalAudioEntry].self, from: Data(contentsOf: index))
                var known: Set<UUID> = []
                entries = saved.filter { $0.hasSafeFilename && known.insert($0.id).inserted }
            }
        } catch {
            storageFailure = error
            errorMessage = error.localizedDescription
        }
    }

    var tracks: [Track] { entries.map { $0.track(in: directory) } }

    func localURL(for track: Track) -> URL? {
        guard let id = track.localFileID, let entry = entries.first(where: { $0.id == id }),
              entry.hasSafeFilename else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting else { return }
        if let storageFailure { errorMessage = storageFailure.localizedDescription; return }
        isImporting = true
        importedCount = 0
        errorMessage = nil
        defer { isImporting = false }
        for url in urls {
            if Task.isCancelled { return }
            do {
                let entry = try await importer.stage(url, in: directory)
                if Task.isCancelled || entries.contains(where: { $0.digest == entry.digest }) {
                    await importer.removeFiles(entry, in: directory)
                    if Task.isCancelled { return }
                    continue
                }
                let updated = [entry] + entries
                do {
                    try persist(updated)
                    entries = updated
                    importedCount += 1
                } catch {
                    await importer.removeFiles(entry, in: directory)
                    throw error
                }
            } catch is CancellationError { return
            } catch {
                errorMessage = L10n.format("local_audio.import_failed", url.lastPathComponent, error.localizedDescription)
            }
        }
    }

    func remove(_ entry: LocalAudioEntry) async throws {
        let updated = entries.filter { $0.id != entry.id }
        try persist(updated)
        entries = updated
        await importer.removeFiles(entry, in: directory)
    }

    private func persist(_ updated: [LocalAudioEntry]) throws {
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}

/// File coordination, hashing, artwork decoding and copies run off the main actor.
private actor LocalAudioImporter {
    func stage(_ source: URL, in directory: URL) async throws -> LocalAudioEntry {
        let ext = source.pathExtension.lowercased()
        guard LocalAudioImportPolicy.extensions.contains(ext) else { throw LocalAudioError.unsupported }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let staged = directory.appendingPathComponent(".import-" + id.uuidString + "." + ext)
        let destination = directory.appendingPathComponent(id.uuidString + "." + ext)
        let artworkURL = LocalAudioPaths.artworkURL(for: id, in: directory)
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: staged)
            if !committed {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: artworkURL)
            }
        }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let bytes = size.fileSize,
                      bytes > 0, bytes <= LocalAudioImportPolicy.maximumBytes else { throw LocalAudioError.invalidSize }
                try FileManager.default.copyItem(at: url, to: staged)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try Task.checkCancellation()
        let copiedSize = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize > 0, copiedSize <= LocalAudioImportPolicy.maximumBytes else { throw LocalAudioError.invalidSize }
        let asset = AVURLAsset(url: staged)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw LocalAudioError.unplayable
        }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await text(.commonIdentifierTitle, in: metadata)
            ?? source.deletingPathExtension().lastPathComponent
        let artist = await text(.commonIdentifierArtist, in: metadata) ?? L10n.text("local_audio.unknown_artist")
        let album = await text(.commonIdentifierAlbumName, in: metadata)
        let hasArtwork = await saveArtwork(metadata, to: artworkURL)
        var hash = SHA256()
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        while let bytes = try handle.read(upToCount: 524_288), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: destination)
        committed = true
        return LocalAudioEntry(id: id, filename: destination.lastPathComponent, title: title, artist: artist,
                               album: album, duration: duration, digest: digest, hasArtwork: hasArtwork, importedAt: Date())
    }

    func removeFiles(_ entry: LocalAudioEntry, in directory: URL) {
        guard entry.hasSafeFilename else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
        try? FileManager.default.removeItem(at: LocalAudioPaths.artworkURL(for: entry.id, in: directory))
    }

    private func text(_ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func saveArtwork(_ metadata: [AVMetadataItem], to url: URL) async -> Bool {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue), data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
