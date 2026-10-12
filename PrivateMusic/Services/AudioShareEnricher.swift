import AVFoundation
import Foundation

actor AudioShareEnricher {
    func enrich(_ url: URL, track: Track, artwork: Data?, lyrics: Lyrics?) async throws {
        try Task.checkCancellation()
        do {
            if url.pathExtension.lowercased() == "mp3" {
                try ID3MetadataWriter.write(url: url, track: track, artwork: artwork)
            } else if url.pathExtension.lowercased() == "m4a" {
                try await tagM4A(url, track: track, artwork: artwork)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            AppLog.shared.failure(.app, "Write audio metadata", error)
        }
        try Task.checkCancellation()
        if let lyrics, !lyrics.text.isEmpty {
            let synchronized = lyrics.lines.filter { $0.time.isFinite && $0.time >= 0 && $0.time < 31_536_000 }
            let text = synchronized.isEmpty ? lyrics.text : synchronized.map { line in
                let ticks = Int((line.time * 100).rounded())
                return String(format: "[%02d:%02d.%02d]",
                              ticks / 6000, (ticks / 100) % 60, ticks % 100) + line.text
            }.joined(separator: "\n")
            try text.write(to: url.deletingPathExtension().appendingPathExtension(synchronized.isEmpty ? "txt" : "lrc"),
                           atomically: true, encoding: .utf8)
        }
    }

    func tagM4A(_ url: URL, track: Track, artwork: Data?) async throws {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ID3MetadataWriter.TagError.unsupportedTag
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var replaced = Set<AVMetadataKey>()
        if !track.title.isEmpty { replaced.insert(.commonKeyTitle) }
        if !track.artist.isEmpty { replaced.insert(.commonKeyArtist) }
        if !(track.albumTitle ?? "").isEmpty { replaced.insert(.commonKeyAlbumName) }
        if artwork != nil { replaced.insert(.commonKeyArtwork) }
        var metadata = try await asset.load(.metadata).filter { item in
            !(item.commonKey.map { replaced.contains($0) } ?? false)
        }
        for (id, value) in [(AVMetadataIdentifier.commonIdentifierTitle, track.title),
                            (.commonIdentifierArtist, track.artist), (.commonIdentifierAlbumName, track.albumTitle ?? "")] {
            guard !value.isEmpty else { continue }
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = value as NSString
            metadata.append(item)
        }
        if let artwork {
            let item = AVMutableMetadataItem(); item.identifier = .commonIdentifierArtwork
            item.value = artwork as NSData; item.dataType = kCMMetadataBaseDataType_JPEG as String
            metadata.append(item)
        }
        exporter.metadata = metadata
        exporter.outputURL = temporary
        exporter.outputFileType = .m4a
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: { exporter.cancelExport() }
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? ID3MetadataWriter.TagError.invalidTag
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
