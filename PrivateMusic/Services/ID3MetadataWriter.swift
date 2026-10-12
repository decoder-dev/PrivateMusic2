import Foundation

/// Replaces only title/artist/album/artwork frames. MPEG audio bytes are copied verbatim.
enum ID3MetadataWriter {
    enum TagError: Error { case unsupportedTag, invalidTag }

    static func write(url: URL, track: Track, artwork: Data?) throws {
        let validArtwork = artwork.flatMap { !$0.isEmpty && $0.count < 2_000_000 ? $0 : nil }
        let texts = [("TIT2", track.title), ("TPE1", track.artist), ("TALB", track.albumTitle ?? "")]
        var replaced = Set(texts.filter { !$0.1.isEmpty }.map { $0.0 })
        if validArtwork != nil { replaced.insert("APIC") }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 10) ?? Data()
        var version: UInt8 = 4
        var skip: UInt64 = 0
        var retained = Data()
        if header.prefix(3) == Data("ID3".utf8) {
            guard header.count == 10, [3, 4].contains(header[3]), header[5] == 0 else {
                throw TagError.unsupportedTag
            }
            version = header[3]
            let length = try decodeSize(header.suffix(4), synchsafe: true)
            guard length <= 4_000_000 else { throw TagError.invalidTag }
            let body = try input.read(upToCount: length) ?? Data()
            guard body.count == length else { throw TagError.invalidTag }
            skip = UInt64(10 + length)
            var position = 0
            while position + 10 <= body.count, body[position] != 0 {
                let id = String(decoding: body[position..<(position + 4)], as: UTF8.self)
                let size = try decodeSize(body[(position + 4)..<(position + 8)], synchsafe: version == 4)
                guard size <= body.count - position - 10 else { throw TagError.invalidTag }
                if !replaced.contains(id) {
                    retained.append(body[position..<(position + 10 + size)])
                }
                position += 10 + size
            }
        }
        var frames = retained
        for (id, text) in texts {
            guard !text.isEmpty else { continue }
            var value = Data([version == 3 ? 1 : 3])
            value.append(text.data(using: version == 3 ? .utf16 : .utf8) ?? Data())
            frames.append(frame(id, value: value, version: version))
        }
        if let artwork = validArtwork {
            var value = Data([0]); value.append(Data("image/jpeg".utf8)); value.append(contentsOf: [0, 3, 0])
            value.append(artwork)
            frames.append(frame("APIC", value: value, version: version))
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.write(contentsOf: Data("ID3".utf8) + Data([version, 0, 0]) + encodeSize(frames.count, synchsafe: true))
            try output.write(contentsOf: frames)
            try input.seek(toOffset: skip)
            while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: bytes)
            }
            try output.close()
            try Task.checkCancellation()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch { try? output.close(); throw error }
    }

    private static func frame(_ id: String, value: Data, version: UInt8) -> Data {
        Data(id.utf8) + encodeSize(value.count, synchsafe: version == 4) + Data([0, 0]) + value
    }

    static func decodeSize(_ bytes: Data.SubSequence, synchsafe: Bool) throws -> Int {
        guard bytes.count == 4, !synchsafe || bytes.allSatisfy({ $0 < 128 }) else { throw TagError.invalidTag }
        return bytes.reduce(0) { ($0 << (synchsafe ? 7 : 8)) | Int($1) }
    }

    private static func encodeSize(_ value: Int, synchsafe: Bool) -> Data {
        let bits = synchsafe ? 7 : 8
        return Data((0..<4).reversed().map { UInt8((value >> ($0 * bits)) & (synchsafe ? 127 : 255)) })
    }
}
