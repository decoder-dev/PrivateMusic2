import Foundation

/// Demuxes HLS CMAF/fMP4 audio by parsing boxes directly instead of handing
/// a stitched, hand-built MP4 to AVFoundation — the current cause of the
/// real-device `-11800`/`-17913` failures.
///
/// Supports `mp4a` (AAC) sample descriptions, `esds` AudioSpecificConfig
/// extraction, `trex` defaults and the `tfhd`/`tfdt`/`trun` triplet of each
/// `traf`. Unsupported codecs surface as a typed `unsupportedCodec` error.
struct CMAFAudioDemuxer {

    // MARK: - Models

    enum Codec: String, Equatable, Sendable {
        case aac = "mp4a"
        case alac, ac3, eac3
        case unsupported
    }

    struct InitializationInfo: Sendable, Equatable {
        let trackID: UInt32
        let timescale: UInt32
        let sampleRate: Double
        let channelCount: UInt32
        let codec: Codec
        let audioSpecificConfig: Data?
        /// MPEG-4 elementary stream descriptor stored after the four-byte
        /// FullBox header of `esds`. Core Audio expects this complete ESDS as
        /// the AAC magic cookie, not only DecoderSpecificInfo (ASC).
        let elementaryStreamDescriptor: Data?
        let defaultSampleDuration: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
    }

    struct CompressedSample: Sendable, Equatable {
        let data: Data
        let decodeTime: Int64
        let presentationTime: Int64
        let duration: Int64
        let isSync: Bool
    }

    enum CMAFError: Error, Sendable, Equatable {
        case invalidInitialization
        case noAudioTrack
        case unsupportedCodec(String)
        case missingMovieBox
        case missingTrackFragmentHeader
        case trackIDMismatch(expected: UInt32, found: UInt32)
        case sampleOutsideMediaData
        case missingSampleSize
        case missingMediaData
    }

    // MARK: - Initialization segment

    /// Parses `ftyp` + `moov` and selects the audio track
    /// (`hdlr.handler_type == "soun"`).
    func parseInitialization(_ data: Data) throws -> InitializationInfo {
        let reader = ISOBoxReader(data)
        let boxes = try reader.boxes()
        guard boxes.contains(where: { $0.type == "ftyp" }) else {
            throw CMAFError.invalidInitialization
        }
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw CMAFError.missingMovieBox
        }

        var selected: InitializationInfo?
        var fallback: InitializationInfo?
        for trak in try reader.children(of: moov) where trak.type == "trak" {
            guard let info = try? parseTrak(trak, in: reader) else {
                continue
            }
            if info.isAudio {
                selected = info.config
                break
            }
            if fallback == nil { fallback = info.config }
        }
        guard let config = selected ?? fallback else {
            throw CMAFError.noAudioTrack
        }
        guard config.codec != .unsupported else {
            throw CMAFError.unsupportedCodec(config.codec.rawValue)
        }

        // Fold trex defaults for this track in from `mvex`.
        if let mvex = try reader.child("mvex", in: moov),
           let trex = try children(of: mvex, in: reader)
               .first(where: { $0.type == "trex" }),
           let trexDefaults = try trexDefaults(trex, reader: reader),
           trexDefaults.trackID == config.trackID {
            return InitializationInfo(
                trackID: config.trackID,
                timescale: config.timescale,
                sampleRate: config.sampleRate,
                channelCount: config.channelCount,
                codec: config.codec,
                audioSpecificConfig: config.audioSpecificConfig,
                elementaryStreamDescriptor: config.elementaryStreamDescriptor,
                defaultSampleDuration: config.defaultSampleDuration
                    ?? trexDefaults.duration,
                defaultSampleSize: config.defaultSampleSize
                    ?? trexDefaults.size,
                defaultSampleFlags: config.defaultSampleFlags
                    ?? trexDefaults.flags
            )
        }
        return config
    }

    // MARK: - Media fragments

    /// Parses one `moof`/`mdat` fragment into compressed AAC samples.
    /// `runEnd` supplies a running decode timestamp for streams that omit
    /// `tfdt` on later fragments. `tfhd`/`trun`/`mdat` slicing runs in
    /// `PrivateMusicMedia.c` so a fragment does not allocate per-sample
    /// Swift arrays.
    func parseFragment(
        _ data: Data,
        initialization: InitializationInfo,
        decodeTime continuesFrom: inout Int64?
    ) throws -> [CompressedSample] {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw CMAFError.missingMediaData
            }
            var decodeTime = continuesFrom ?? 0
            var hasDecodeTime = continuesFrom != nil
            let incomingDecodeTime = decodeTime
            let incomingHasDecodeTime = hasDecodeTime
            var status = pm_cmaf_status(code: 0, found_track_id: 0)
            let total = pm_cmaf_extract_fragment(
                base,
                Int32(data.count),
                initialization.trackID,
                initialization.defaultSampleDuration ?? 0,
                initialization.defaultSampleDuration != nil,
                initialization.defaultSampleSize ?? 0,
                initialization.defaultSampleSize != nil,
                initialization.defaultSampleFlags ?? 0,
                initialization.defaultSampleFlags != nil,
                &decodeTime,
                &hasDecodeTime,
                nil,
                0,
                &status
            )
            try Self.throwIfNeeded(
                status,
                expectedTrackID: initialization.trackID
            )
            guard total > 0 else { throw CMAFError.missingMediaData }
            var table = [pm_cmaf_sample](
                repeating: pm_cmaf_sample(
                    offset: 0,
                    size: 0,
                    decode_time: 0,
                    presentation_time: 0,
                    duration: 0,
                    is_sync: false
                ),
                count: Int(total)
            )
            decodeTime = incomingDecodeTime
            hasDecodeTime = incomingHasDecodeTime
            let count = table.withUnsafeMutableBufferPointer { buffer in
                pm_cmaf_extract_fragment(
                    base,
                    Int32(data.count),
                    initialization.trackID,
                    initialization.defaultSampleDuration ?? 0,
                    initialization.defaultSampleDuration != nil,
                    initialization.defaultSampleSize ?? 0,
                    initialization.defaultSampleSize != nil,
                    initialization.defaultSampleFlags ?? 0,
                    initialization.defaultSampleFlags != nil,
                    &decodeTime,
                    &hasDecodeTime,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    &status
                )
            }
            try Self.throwIfNeeded(
                status,
                expectedTrackID: initialization.trackID
            )
            guard count > 0 else { throw CMAFError.missingMediaData }
            if hasDecodeTime {
                continuesFrom = decodeTime
            }
            return table.prefix(Int(count)).map { sample in
                let start = Int(sample.offset)
                let end = start + Int(sample.size)
                return CompressedSample(
                    data: data.subdata(in: start..<end),
                    decodeTime: sample.decode_time,
                    presentationTime: sample.presentation_time,
                    duration: sample.duration,
                    isSync: sample.is_sync
                )
            }
        }
    }

    private static func throwIfNeeded(
        _ status: pm_cmaf_status,
        expectedTrackID: UInt32
    ) throws {
        switch status.code {
        case PM_CMAF_OK:
            return
        case PM_CMAF_MISSING_TFHD:
            throw CMAFError.missingTrackFragmentHeader
        case PM_CMAF_TRACK_MISMATCH:
            throw CMAFError.trackIDMismatch(
                expected: expectedTrackID,
                found: status.found_track_id
            )
        case PM_CMAF_MISSING_SIZE:
            throw CMAFError.missingSampleSize
        case PM_CMAF_SAMPLE_OUTSIDE:
            throw CMAFError.sampleOutsideMediaData
        case PM_CMAF_MISSING_MDAT, PM_CMAF_OVERFLOW:
            throw CMAFError.missingMediaData
        default:
            throw CMAFError.missingMovieBox
        }
    }

    // MARK: - Parsing internals

    private struct TrakInfo {
        let isAudio: Bool
        let config: InitializationInfo
    }

    private func parseTrak(
        _ trak: ISOBoxReader.ISOBox,
        in reader: ISOBoxReader
    ) throws -> TrakInfo {
        guard let tkhd = try reader.child("tkhd", in: trak),
              let mdia = try reader.child("mdia", in: trak),
              let mdhd = try reader.child("mdhd", in: mdia),
              let hdlr = try reader.child("hdlr", in: mdia),
              let minf = try reader.child("minf", in: mdia),
              let stbl = try reader.child("stbl", in: minf),
              let stsd = try reader.child("stsd", in: stbl) else {
            throw CMAFError.invalidInitialization
        }

        let trackID = try tkhdTrackID(tkhd, reader: reader)
        guard trackID > 0 else { throw CMAFError.invalidInitialization }
        let timescale = try mdhdTimescale(mdhd, reader: reader)
        guard timescale > 0 else { throw CMAFError.invalidInitialization }

        let handlerType = try fourCC(
            reader,
            at: hdlr.payloadRange.lowerBound + 8
        )
        let isAudio = handlerType == "soun"

        // Audio sample entries: 8-byte version/flags + entry count + sample
        // entry headers (28 bytes each) followed by `esds` etc.
        guard let entry = try reader.children(of: stsd, skipping: 8).first else {
            throw CMAFError.invalidInitialization
        }
        let codec = Codec(rawValue: entry.type) ?? .unsupported
        let (channels, sampleRate) = try audioSampleEntry(entry, reader: reader)
        let esds = try esdsConfiguration(entry, reader: reader)

        return TrakInfo(
            isAudio: isAudio,
            config: InitializationInfo(
                trackID: trackID,
                timescale: timescale,
                sampleRate: sampleRate ?? 44_100,
                channelCount: channels ?? 2,
                codec: codec,
                audioSpecificConfig: esds.audioSpecificConfig,
                elementaryStreamDescriptor: esds.elementaryStreamDescriptor,
                defaultSampleDuration: nil,
                defaultSampleSize: nil,
                defaultSampleFlags: nil
            )
        )
    }

    private func tkhdTrackID(
        _ box: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> UInt32 {
        let version = try reader.readUInt8(at: box.payloadRange.lowerBound)
        if version == 1 {
            return try reader.readUInt32BE(
                at: box.payloadRange.lowerBound + 20
            )
        }
        return try reader.readUInt32BE(at: box.payloadRange.lowerBound + 12)
    }

    private func mdhdTimescale(
        _ box: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> UInt32 {
        let version = try reader.readUInt8(at: box.payloadRange.lowerBound)
        let body = box.payloadRange.lowerBound + 4
        return version == 1
            ? try reader.readUInt32BE(at: body + 20)
            : try reader.readUInt32BE(at: body + 12)
    }

    /// Audio sample entry fields once past the 8-byte entry header:
    /// reserved(6) data_reference_index(2) reserved(8) channels(2)
    /// sample_size(2) predefined(2) reserved(2) sample_rate(16.16 fixed, 4).
    private func audioSampleEntry(
        _ entry: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> (UInt32?, Double?) {
        let body = entry.payloadRange.lowerBound
        let channels = UInt32(try reader.readUInt16BE(at: body + 16))
        let rateFixed = try reader.readUInt32BE(at: body + 24)
        let sampleRate = rateFixed > 0 ? Double(rateFixed >> 16) : nil
        return (channels > 0 ? channels : nil, sampleRate)
    }

    /// `esds` contains an MPEG-4 ES_Descriptor; the AAC AudioSpecificConfig
    /// lives in the DecoderSpecificInfo tag (0x05).
    private func esdsConfiguration(
        _ entry: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> (
        audioSpecificConfig: Data?,
        elementaryStreamDescriptor: Data?
    ) {
        guard entry.type == "mp4a",
              let esds = try reader.child(
                "esds",
                in: entry,
                skipping: 28
              ) else {
            return (nil, nil)
        }
        let descriptorStart = esds.payloadRange.lowerBound + 4
        guard descriptorStart < esds.payloadRange.upperBound else {
            return (nil, nil)
        }
        let descriptor = try reader.readBytes(
            at: descriptorStart..<esds.payloadRange.upperBound
        )
        let asc = try decoderSpecificInfo(
            in: descriptorStart..<esds.payloadRange.upperBound,
            reader: reader
        )
        return (asc, descriptor)
    }

    /// Searches nested MPEG-4 descriptors. ES_Descriptor (0x03) and
    /// DecoderConfigDescriptor (0x04) contain small fixed headers before
    /// their children, so a flat top-level walk cannot reach tag 0x05.
    private func decoderSpecificInfo(
        in range: Range<Int>,
        reader: ISOBoxReader
    ) throws -> Data? {
        var offset = range.lowerBound
        let limit = range.upperBound
        while offset + 2 <= limit {
            let tag = try reader.readUInt8(at: offset)
            offset += 1
            var size: UInt32 = 0
            var read = 0
            while read < 4 {
                let byte = try reader.readUInt8(at: offset)
                offset += 1
                read += 1
                size = (size << 7) | UInt32(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard offset + Int(size) <= limit else { break }
            if tag == 0x05 {
                return try reader.readBytes(at: offset..<(offset + Int(size)))
            }
            let payloadEnd = offset + Int(size)
            let nestedStart: Int?
            switch tag {
            case 0x03:
                // ES_ID(2), flags(1); optional fields are not used by CMAF
                // audio produced by AVFoundation/VK.
                nestedStart = offset + 3
            case 0x04:
                // objectTypeIndication(1), streamType(1), bufferSizeDB(3),
                // maxBitrate(4), avgBitrate(4).
                nestedStart = offset + 13
            default:
                nestedStart = nil
            }
            if let nestedStart, nestedStart < payloadEnd,
               let nested = try decoderSpecificInfo(
                   in: nestedStart..<payloadEnd,
                   reader: reader
               ) {
                return nested
            }
            offset = payloadEnd
        }
        return nil
    }

    private func trexDefaults(
        _ trex: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> (trackID: UInt32, duration: UInt32, size: UInt32, flags: UInt32)? {
        let body = trex.payloadRange.lowerBound
        return (
            try reader.readUInt32BE(at: body + 4),
            try reader.readUInt32BE(at: body + 12),
            try reader.readUInt32BE(at: body + 16),
            try reader.readUInt32BE(at: body + 20)
        )
    }

    // MARK: - Shared box helpers

    private func children(
        of box: ISOBoxReader.ISOBox,
        in reader: ISOBoxReader
    ) throws -> [ISOBoxReader.ISOBox] {
        try reader.children(of: box)
    }

    private func fourCC(
        _ reader: ISOBoxReader,
        at offset: Int
    ) throws -> String {
        let bytes = try reader.readBytes(at: offset..<(offset + 4))
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

private extension CMAFAudioDemuxer.InitializationInfo {
    var config: CMAFAudioDemuxer.InitializationInfo { self }
}
