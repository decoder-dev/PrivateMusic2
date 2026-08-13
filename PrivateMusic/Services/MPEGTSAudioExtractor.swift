import Foundation

/// Pulls an elementary audio stream out of concatenated MPEG-TS HLS
/// segments so AVFoundation can open it. Stitched `.ts` files often trip
/// `AVError.fileFailedToParse` (-11828) because of PAT/PMT repetition and
/// discontinuities; a raw ADTS/MP3 elementary stream does not.
enum MPEGTSAudioExtractor {
    enum OutputKind: Equatable, Sendable {
        case adtsAAC
        case mp3
        case unknown

        var fileExtension: String {
            switch self {
            case .adtsAAC: return "aac"
            case .mp3: return "mp3"
            case .unknown: return "bin"
            }
        }
    }

    struct Extraction: Equatable, Sendable {
        let data: Data
        let kind: OutputKind
    }

    /// Returns demuxed audio when the buffer is MPEG-TS with a recognizable
    /// AAC ADTS or MPEG audio elementary stream. `nil` means "leave the
    /// original bytes alone". Packet walk, PAT/PMT and PES drain run in
    /// `PrivateMusicMedia.c` so a 50k-packet stitch does not allocate a
    /// `Data` slice per packet.
    static func extractAudio(from data: Data) -> Extraction? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw -> Extraction? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            let capacity = data.count
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer {
                output.deallocate()
                scratch.deallocate()
            }
            var length: Int32 = 0
            let kind = pm_mpegts_extract_audio(
                base,
                Int32(capacity),
                output,
                Int32(capacity),
                scratch,
                Int32(capacity),
                &length
            )
            guard length > 32 else { return nil }
            switch kind {
            case PM_MPEGTS_KIND_ADTS:
                return Extraction(
                    data: Data(bytes: output, count: Int(length)),
                    kind: .adtsAAC
                )
            case PM_MPEGTS_KIND_MP3:
                return Extraction(
                    data: Data(bytes: output, count: Int(length)),
                    kind: .mp3
                )
            default:
                return nil
            }
        }
    }

    /// Demuxes a stitched MPEG-TS file packet-by-packet. Neither the source
    /// nor the elementary stream is materialized in memory.
    static func extractAudioFile(
        from sourceURL: URL,
        toDirectory directory: URL
    ) throws -> (url: URL, kind: OutputKind)? {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        let probe = try input.read(upToCount: 204 * 3) ?? Data()
        guard let packetSize = packetSize(in: probe) else { return nil }
        try input.seek(toOffset: 0)

        guard let program = try discoverProgram(
            in: input,
            packetSize: packetSize
        ) else {
            return nil
        }
        try input.seek(toOffset: 0)

        let temporaryURL = directory.appendingPathComponent("elementary.tmp")
        _ = FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil
        )
        let output = try FileHandle(forWritingTo: temporaryURL)
        var written = 0
        var remainingPES = PM_MPEGTS_PES_UNBOUNDED

        do {
            while let packet = try readPacket(from: input, size: packetSize) {
                try packet.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress
                    else {
                        return
                    }
                    var pid: Int32 = 0
                    var unitStart = false
                    var payloadOffset: Int32 = 0
                    var payloadLength: Int32 = 0
                    guard pm_mpegts_parse_packet(
                        base,
                        Int32(packet.count),
                        &pid,
                        &unitStart,
                        &payloadOffset,
                        &payloadLength
                    ), pid == program.audioPID else {
                        return
                    }
                    var elementaryOffset: Int32 = 0
                    var elementaryLength: Int32 = 0
                    guard pm_mpegts_pes_slice(
                        base + Int(payloadOffset),
                        payloadLength,
                        unitStart,
                        &remainingPES,
                        &elementaryOffset,
                        &elementaryLength
                    ) else {
                        return
                    }
                    let slice = UnsafeRawBufferPointer(
                        start: base + Int(payloadOffset) + Int(elementaryOffset),
                        count: Int(elementaryLength)
                    )
                    try output.write(contentsOf: slice)
                    written += Int(elementaryLength)
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        guard written > 32 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }

        let kind: OutputKind
        if let known = outputKind(forStreamType: program.streamType) {
            kind = known
        } else {
            let elementary = try FileHandle(forReadingFrom: temporaryURL)
            let prefix = try elementary.read(upToCount: 16) ?? Data()
            try elementary.close()
            kind = inferKind(from: prefix)
        }
        guard kind != .unknown else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }

        let finalURL = directory
            .appendingPathComponent("elementary")
            .appendingPathExtension(kind.fileExtension)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        return (finalURL, kind)
    }

    // MARK: - Discovery

    private struct ProgramInfo {
        let audioPID: Int
        let streamType: UInt8
    }

    private static func readPacket(
        from handle: FileHandle,
        size: Int
    ) throws -> Data? {
        guard let data = try handle.read(upToCount: size),
              !data.isEmpty else {
            return nil
        }
        guard data.count == size else { return nil }
        return data
    }

    private static func discoverProgram(
        in handle: FileHandle,
        packetSize: Int
    ) throws -> ProgramInfo? {
        var pmtPID: Int?
        var fallbackAudioPID: Int?

        // PSI tables occur near the beginning of each HLS segment. Limit the
        // scan while still spanning multiple segment boundaries.
        for _ in 0..<50_000 {
            guard let packet = try readPacket(
                from: handle,
                size: packetSize
            ) else {
                break
            }
            let discovered: ProgramInfo? = packet.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress
                else {
                    return nil
                }
                var pid: Int32 = 0
                var unitStart = false
                var payloadOffset: Int32 = 0
                var payloadLength: Int32 = 0
                guard pm_mpegts_parse_packet(
                    base,
                    Int32(packet.count),
                    &pid,
                    &unitStart,
                    &payloadOffset,
                    &payloadLength
                ) else {
                    return nil
                }
                let payload = base + Int(payloadOffset)
                if pid == 0, pmtPID == nil {
                    let parsed = pm_mpegts_parse_pat(payload, payloadLength)
                    if parsed >= 0 {
                        pmtPID = Int(parsed)
                    }
                    return nil
                }
                if let pmtPID, pid == pmtPID {
                    var audioPID: Int32 = 0
                    var streamType: UInt8 = 0
                    if pm_mpegts_parse_pmt(
                        payload,
                        payloadLength,
                        &audioPID,
                        &streamType
                    ) {
                        return ProgramInfo(
                            audioPID: Int(audioPID),
                            streamType: streamType
                        )
                    }
                    return nil
                }
                if fallbackAudioPID == nil,
                   unitStart,
                   payloadLength >= 4,
                   payload[0] == 0,
                   payload[1] == 0,
                   payload[2] == 1,
                   (0xC0...0xDF).contains(payload[3]) {
                    fallbackAudioPID = Int(pid)
                }
                return nil
            }
            if let discovered {
                return discovered
            }
        }

        return fallbackAudioPID.map {
            ProgramInfo(audioPID: $0, streamType: 0)
        }
    }

    private static func packetSize(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            let size = pm_mpegts_packet_size(base, Int32(data.count))
            return size > 0 ? Int(size) : nil
        }
    }

    private static func outputKind(
        forStreamType streamType: UInt8
    ) -> OutputKind? {
        switch streamType {
        case 0x0F: return .adtsAAC
        case 0x03, 0x04: return .mp3
        default: return nil
        }
    }

    private static func inferKind(from data: Data) -> OutputKind {
        if looksLikeADTS(data) { return .adtsAAC }
        if looksLikeMP3(data) { return .mp3 }
        return .unknown
    }

    private static func looksLikeADTS(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0xFF && data[1] & 0xF6 == 0xF0
    }

    private static func looksLikeMP3(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        if data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            return true
        }
        guard data[0] == 0xFF else { return false }
        let versionBits = (data[1] >> 3) & 0x03
        let layerBits = (data[1] >> 1) & 0x03
        guard versionBits != 1, layerBits != 0 else { return false }
        return data[1] & 0xE0 == 0xE0
    }
}
