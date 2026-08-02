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
    /// original bytes alone".
    static func extractAudio(from data: Data) -> Extraction? {
        guard let packetSize = packetSize(in: data) else { return nil }
        guard let program = discoverProgram(in: data, packetSize: packetSize)
        else {
            return extractByPESScan(in: data, packetSize: packetSize)
        }
        return extract(
            pid: program.audioPID,
            streamType: program.streamType,
            from: data,
            packetSize: packetSize
        )
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
        var remainingPESPayload: Int?

        do {
            while let packet = try readPacket(from: input, size: packetSize) {
                guard let parsed = packetPayload(packet),
                      parsed.pid == program.audioPID else {
                    continue
                }

                var payload = parsed.payload
                if parsed.payloadUnitStart {
                    guard payload.count >= 9,
                          payload[0] == 0,
                          payload[1] == 0,
                          payload[2] == 1 else {
                        remainingPESPayload = nil
                        continue
                    }
                    let packetLength = Int(payload[4]) << 8 | Int(payload[5])
                    let headerLength = Int(payload[8])
                    let payloadStart = 9 + headerLength
                    guard payloadStart <= payload.count else {
                        remainingPESPayload = nil
                        continue
                    }
                    payload = payload.subdata(in: payloadStart..<payload.count)
                    remainingPESPayload = packetLength == 0
                        ? nil
                        : max(0, packetLength - 3 - headerLength)
                } else if remainingPESPayload == 0 {
                    continue
                }

                let count = min(
                    payload.count,
                    remainingPESPayload ?? payload.count
                )
                if count > 0 {
                    try output.write(contentsOf: payload.prefix(count))
                    written += count
                    if let remaining = remainingPESPayload {
                        remainingPESPayload = max(0, remaining - count)
                    }
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

    private struct PacketPayload {
        let pid: Int
        let payloadUnitStart: Bool
        let payload: Data
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

    private static func packetPayload(_ packet: Data) -> PacketPayload? {
        guard packet.count >= 4, packet[0] == 0x47 else { return nil }
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let payloadUnitStart = packet[1] & 0x40 != 0
        let adaptationControl = (packet[3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else {
            return nil
        }
        var offset = 4
        if adaptationControl == 3 {
            guard offset < packet.count else { return nil }
            offset += 1 + Int(packet[offset])
        }
        guard offset < packet.count else { return nil }
        return PacketPayload(
            pid: pid,
            payloadUnitStart: payloadUnitStart,
            payload: packet.subdata(in: offset..<packet.count)
        )
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
            guard let parsed = packetPayload(packet) else { continue }

            if parsed.pid == 0, pmtPID == nil {
                pmtPID = parsePAT(parsed.payload)
                continue
            }
            if let pmtPID, parsed.pid == pmtPID {
                if let program = parsePMT(parsed.payload) {
                    return program
                }
                continue
            }
            if fallbackAudioPID == nil,
               parsed.payloadUnitStart,
               parsed.payload.count >= 4,
               parsed.payload[0] == 0,
               parsed.payload[1] == 0,
               parsed.payload[2] == 1,
               (0xC0...0xDF).contains(parsed.payload[3]) {
                fallbackAudioPID = parsed.pid
            }
        }

        return fallbackAudioPID.map {
            ProgramInfo(audioPID: $0, streamType: 0)
        }
    }

    private static func packetSize(in data: Data) -> Int? {
        for size in [188, 192, 204] {
            var syncs = 0
            var offset = 0
            while offset + size <= data.count {
                if data[offset] != 0x47 { break }
                syncs += 1
                if syncs >= 3 { return size }
                offset += size
            }
            if syncs >= 2, offset >= data.count { return size }
        }
        return nil
    }

    private static func discoverProgram(
        in data: Data,
        packetSize: Int
    ) -> ProgramInfo? {
        var pmtPID: Int?
        forEachPayload(in: data, packetSize: packetSize) { pid, payload in
            if pid == 0, pmtPID == nil {
                pmtPID = parsePAT(payload)
            }
        }
        guard let pmtPID else { return nil }
        var program: ProgramInfo?
        forEachPayload(in: data, packetSize: packetSize) { pid, payload in
            guard program == nil, pid == pmtPID else { return }
            program = parsePMT(payload)
        }
        return program
    }

    private static func parsePAT(_ payload: Data) -> Int? {
        guard let section = psiSection(from: payload),
              section.count >= 8,
              section[0] == 0x00 else {
            return nil
        }
        let sectionLength = Int(section[1] & 0x0F) << 8 | Int(section[2])
        // section_length counts bytes after the length field through CRC.
        let sectionEnd = 3 + sectionLength
        guard section.count >= sectionEnd, sectionEnd >= 12 else {
            return nil
        }
        var offset = 8
        let end = sectionEnd - 4
        while offset + 4 <= end {
            let programNumber = Int(section[offset]) << 8
                | Int(section[offset + 1])
            let pid = Int(section[offset + 2] & 0x1F) << 8
                | Int(section[offset + 3])
            offset += 4
            if programNumber != 0 {
                return pid
            }
        }
        return nil
    }

    private static func parsePMT(_ payload: Data) -> ProgramInfo? {
        guard let section = psiSection(from: payload),
              section.count >= 12,
              section[0] == 0x02 else {
            return nil
        }
        let sectionLength = Int(section[1] & 0x0F) << 8 | Int(section[2])
        let sectionEnd = 3 + sectionLength
        guard section.count >= sectionEnd, sectionEnd >= 16 else {
            return nil
        }
        let programInfoLength = Int(section[10] & 0x0F) << 8
            | Int(section[11])
        var offset = 12 + programInfoLength
        let end = sectionEnd - 4
        var preferred: ProgramInfo?
        while offset + 5 <= end {
            let streamType = section[offset]
            let elementaryPID = Int(section[offset + 1] & 0x1F) << 8
                | Int(section[offset + 2])
            let esInfoLength = Int(section[offset + 3] & 0x0F) << 8
                | Int(section[offset + 4])
            offset += 5 + esInfoLength
            if let kind = outputKind(forStreamType: streamType) {
                let info = ProgramInfo(
                    audioPID: elementaryPID,
                    streamType: streamType
                )
                if kind == .adtsAAC { return info }
                if preferred == nil { preferred = info }
            }
        }
        return preferred
    }

    private static func psiSection(from payload: Data) -> Data? {
        guard !payload.isEmpty else { return nil }
        let pointer = Int(payload[0])
        let start = 1 + pointer
        guard start < payload.count else { return nil }
        return payload.subdata(in: start..<payload.count)
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

    // MARK: - Extraction

    private static func extract(
        pid targetPID: Int,
        streamType: UInt8,
        from data: Data,
        packetSize: Int
    ) -> Extraction? {
        var elementary = Data()
        var pesBuffer = Data()
        forEachPayload(in: data, packetSize: packetSize) { pid, payload in
            guard pid == targetPID else { return }
            pesBuffer.append(payload)
            while let consumed = drainPES(from: &pesBuffer, into: &elementary) {
                if consumed == 0 { break }
            }
        }
        _ = drainPES(from: &pesBuffer, into: &elementary, allowPartial: true)
        guard elementary.count > 32 else { return nil }
        let kind = outputKind(forStreamType: streamType)
            ?? inferKind(from: elementary)
        guard kind != .unknown else { return nil }
        return Extraction(data: elementary, kind: kind)
    }

    private static func extractByPESScan(
        in data: Data,
        packetSize: Int
    ) -> Extraction? {
        // Fallback when PAT/PMT are missing from a short peek: collect every
        // PES with an audio stream id (0xC0...0xDF).
        var elementary = Data()
        var pesBuffer = Data()
        forEachPayload(in: data, packetSize: packetSize) { _, payload in
            pesBuffer.append(payload)
            while let consumed = drainPES(
                from: &pesBuffer,
                into: &elementary,
                audioOnly: true
            ) {
                if consumed == 0 { break }
            }
        }
        _ = drainPES(
            from: &pesBuffer,
            into: &elementary,
            audioOnly: true,
            allowPartial: true
        )
        guard elementary.count > 32 else { return nil }
        let kind = inferKind(from: elementary)
        guard kind != .unknown else { return nil }
        return Extraction(data: elementary, kind: kind)
    }

    @discardableResult
    private static func drainPES(
        from buffer: inout Data,
        into elementary: inout Data,
        audioOnly: Bool = false,
        allowPartial: Bool = false
    ) -> Int? {
        guard let start = findPESStart(in: buffer) else {
            if buffer.count > 10_000 {
                buffer.removeFirst(buffer.count - 3)
            }
            return 0
        }
        if start > 0 {
            buffer.removeFirst(start)
        }
        guard buffer.count >= 9 else { return allowPartial ? 0 : nil }
        let streamID = buffer[3]
        if audioOnly, !(0xC0...0xDF).contains(streamID) {
            buffer.removeFirst(4)
            return 4
        }
        let pesPacketLength = Int(buffer[4]) << 8 | Int(buffer[5])
        let headerDataLength = Int(buffer[8])
        let payloadStart = 9 + headerDataLength
        guard buffer.count >= payloadStart else {
            return allowPartial ? 0 : nil
        }
        let packetEnd: Int
        if pesPacketLength == 0 {
            // Length 0 means "until next start code" — keep waiting unless
            // this is the final flush.
            if !allowPartial { return nil }
            packetEnd = buffer.count
        } else {
            packetEnd = 6 + pesPacketLength
            guard buffer.count >= packetEnd || allowPartial else {
                return nil
            }
        }
        let end = min(packetEnd, buffer.count)
        if payloadStart < end {
            elementary.append(buffer.subdata(in: payloadStart..<end))
        }
        let consumed = end
        buffer.removeFirst(consumed)
        return consumed
    }

    private static func findPESStart(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = 0
        while index + 3 < data.count {
            if data[index] == 0x00,
               data[index + 1] == 0x00,
               data[index + 2] == 0x01 {
                return index
            }
            index += 1
        }
        return nil
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

    // MARK: - Packet walk

    private static func forEachPayload(
        in data: Data,
        packetSize: Int,
        body: (_ pid: Int, _ payload: Data) -> Void
    ) {
        var offset = 0
        while offset + packetSize <= data.count {
            defer { offset += packetSize }
            guard data[offset] == 0x47 else { continue }
            let pid = Int(data[offset + 1] & 0x1F) << 8
                | Int(data[offset + 2])
            let adaptationControl = (data[offset + 3] >> 4) & 0x03
            var payloadOffset = offset + 4
            if adaptationControl == 2 || adaptationControl == 3 {
                guard payloadOffset < offset + packetSize else { continue }
                let adaptationLength = Int(data[payloadOffset])
                payloadOffset += 1 + adaptationLength
            }
            guard adaptationControl == 1 || adaptationControl == 3 else {
                continue
            }
            guard payloadOffset < offset + packetSize else { continue }
            body(
                pid,
                data.subdata(in: payloadOffset..<(offset + packetSize))
            )
        }
    }
}
