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

        var fallback: InitializationInfo?
        for trak in try reader.children(of: moov) where trak.type == "trak" {
            guard let info = try? parseTrak(trak, in: reader) else {
                continue
            }
            if info.isAudio { return info.config }
            if fallback == nil { fallback = info.config }
        }
        guard let config = fallback else {
            throw CMAFError.noAudioTrack
        }
        guard config.codec == .aac else {
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
    /// `tfdt` on later fragments.
    func parseFragment(
        _ data: Data,
        initialization: InitializationInfo,
        decodeTime continuesFrom: inout Int64?
    ) throws -> [CompressedSample] {
        let reader = ISOBoxReader(data)
        let boxes = try reader.boxes()
        guard let moof = boxes.first(where: { $0.type == "moof" }),
              let mdat = boxes.first(where: { $0.type == "mdat" }) else {
            throw CMAFError.missingMovieBox
        }

        var samples: [CompressedSample] = []
        for traf in try children(of: moof, in: reader)
        where traf.type == "traf" {
            samples.append(
                contentsOf: try parseTraf(
                    traf,
                    in: reader,
                    moofBox: moof,
                    data: data,
                    initialization: initialization,
                    decodeTime: &continuesFrom
                )
            )
        }
        guard !samples.isEmpty else {
            throw CMAFError.missingMediaData
        }
        return samples
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
        guard let entry = try reader.children(of: stsd).first else {
            throw CMAFError.invalidInitialization
        }
        let codec = Codec(rawValue: entry.type) ?? .unsupported
        let (channels, sampleRate) = try audioSampleEntry(entry, reader: reader)
        let asc = try esdsAudioSpecificConfig(entry, reader: reader)

        return TrakInfo(
            isAudio: isAudio,
            config: InitializationInfo(
                trackID: trackID,
                timescale: timescale,
                sampleRate: sampleRate ?? 44_100,
                channelCount: channels ?? 2,
                codec: codec,
                audioSpecificConfig: asc,
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
        let channels = UInt32(try reader.readUInt16BE(at: body + 24))
        let rateFixed = try reader.readUInt32BE(at: body + 32)
        let sampleRate = rateFixed > 0 ? Double(rateFixed >> 16) : nil
        return (channels > 0 ? channels : nil, sampleRate)
    }

    /// `esds` contains an MPEG-4 ES_Descriptor; the AAC AudioSpecificConfig
    /// lives in the DecoderSpecificInfo tag (0x05).
    private func esdsAudioSpecificConfig(
        _ entry: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> Data? {
        guard entry.type == "mp4a",
              let esds = try reader.child("esds", in: entry) else {
            return nil
        }
        var offset = esds.payloadRange.lowerBound + 4 // version/flags
        let limit = esds.payloadRange.upperBound
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
            offset += Int(size)
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

    // MARK: - Fragment internals

    private struct TFHD {
        let trackID: UInt32
        let defaultSampleDuration: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
        let defaultBaseIsMoof: Bool
    }

    private struct TRUN {
        let dataOffset: Int64?
        let firstSampleFlags: UInt32?
        let durations: [UInt32?]
        let sizes: [UInt32?]
        let sync: [Bool?]
        let cts: [Int32]
    }

    private func parseTraf(
        _ traf: ISOBoxReader.ISOBox,
        in reader: ISOBoxReader,
        moofBox: ISOBoxReader.ISOBox,
        data: Data,
        initialization: InitializationInfo,
        decodeTime: inout Int64?
    ) throws -> [CompressedSample] {
        let children = try self.children(of: traf, in: reader)
        guard let tfhdBox = children.first(where: { $0.type == "tfhd" }) else {
            throw CMAFError.missingTrackFragmentHeader
        }
        let tfhd = try parseTFHD(tfhdBox, reader: reader)
        guard tfhd.trackID == initialization.trackID else {
            throw CMAFError.trackIDMismatch(
                expected: initialization.trackID,
                found: tfhd.trackID
            )
        }

        var decodeTime: Int64
        if let tfdt = children.first(where: { $0.type == "tfdt" }) {
            decodeTime = try tfdtBaseTime(tfdt, reader: reader)
        } else if let running = decodeTime {
            decodeTime = running
        } else {
            decodeTime = 0
        }

        // For our real HLS CMAF, every fragment is a moof followed by an mdat.
        // Data offsets inside trun are relative to the byte-basis advertised
        // by tfhd; when tfhd-default-base-is-moof (0x20000) is set,
        // mdat.payload starts at moof + moof.len + 8.
        let fragmentData = data
        guard let mdat = try ISOBoxReader(fragmentData).boxes()
            .first(where: { $0.type == "mdat" }) else {
            throw CMAFError.missingMediaData
        }
        let mdatStart = mdat.payloadRange.lowerBound

        var samples: [CompressedSample] = []
        for trunBox in children where trunBox.type == "trun" {
            let trun = try parseTRUN(trunBox, reader: reader)

            let moofBasedStart = moofBox.range.lowerBound + (trun.dataOffset.map(Int.init) ?? 0)
            // Use whichever anchor lands inside mdat; if both do, prefer the
            // tfhd-implied one (authoritative for baseDataOffsetPresent).
            let startInsideMoof = moofBasedStart >= mdatStart
                && moofBasedStart < mdat.payloadRange.upperBound
            let startInsideMoofNextSample = moofBasedStart + Int(trun.sizes[safe: 0] ?? 0) <= mdat.payloadRange.upperBound
            let useMoofAnchor = startInsideMoof && startInsideMoofNextSample
            var sampleOffset = useMoofAnchor ? moofBasedStart : mdatStart

            for index in 0..<max(trun.durations.count, trun.sizes.count) {
                let duration = trun.durations[safe: index] ?? nil
                    ?? tfhd.defaultSampleDuration
                    ?? initialization.defaultSampleDuration
                let size = trun.sizes[safe: index] ?? nil
                    ?? tfhd.defaultSampleSize
                    ?? initialization.defaultSampleSize
                guard let size, size > 0 else {
                    throw CMAFError.missingSampleSize
                }

                let start = sampleOffset
                let end = start + Int(size)
                guard start >= mdatStart, end <= mdat.payloadRange.upperBound
                else {
                    throw CMAFError.sampleOutsideMediaData
                }

                let isSync: Bool
                if let sync = trun.sync[safe: index] ?? nil {
                    isSync = sync
                } else if let flags = tfhd.defaultSampleFlags {
                    isSync = flags & 0x00010000 == 0
                } else {
                    isSync = true
                }

                let presentationTime = decodeTime + Int64(trun.cts[safe: index] ?? 0)
                samples.append(CompressedSample(
                    data: try reader.readBytes(at: start..<end),
                    decodeTime: decodeTime,
                    presentationTime: presentationTime,
                    duration: Int64(duration ?? 0),
                    isSync: isSync
                ))
                decodeTime += Int64(duration ?? 0)
                sampleOffset += Int(size)
            }
        }

        guard !samples.isEmpty else {
            throw CMAFError.missingMediaData
        }
        return samples
    }

    private func parseTFHD(
        _ box: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> TFHD {
        let body = box.payloadRange.lowerBound
        let flags = try reader.readUInt24BE(at: body + 1)
        var offset = body + 8
        let trackID = try reader.readUInt32BE(at: body + 4)

        if flags & 0x000001 != 0 { offset += 8 }   // base-data-offset
        if flags & 0x000002 != 0 { offset += 4 }   // sample-description-index
        let defaultDuration = flags & 0x000008 != 0
            ? try reader.readUInt32BE(at: offset) : nil
        if flags & 0x000008 != 0 { offset += 4 }
        let defaultSize = flags & 0x000010 != 0
            ? try reader.readUInt32BE(at: offset) : nil
        if flags & 0x000010 != 0 { offset += 4 }
        let defaultFlags = flags & 0x000020 != 0
            ? try reader.readUInt32BE(at: offset) : nil

        return TFHD(
            trackID: trackID,
            defaultSampleDuration: defaultDuration,
            defaultSampleSize: defaultSize,
            defaultSampleFlags: defaultFlags,
            defaultBaseIsMoof: flags & 0x020000 != 0
        )
    }

    private func tfdtBaseTime(
        _ box: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> Int64 {
        let body = box.payloadRange.lowerBound
        let version = try reader.readUInt8(at: body)
        return version == 1
            ? Int64(try reader.readUInt64BE(at: body + 4))
            : Int64(try reader.readUInt32BE(at: body + 4))
    }

    private func parseTRUN(
        _ box: ISOBoxReader.ISOBox,
        reader: ISOBoxReader
    ) throws -> TRUN {
        let body = box.payloadRange.lowerBound
        let flags = try reader.readUInt24BE(at: body + 1)
        let sampleCount = Int(try reader.readUInt32BE(at: body + 4))
        guard sampleCount > 0 else { throw CMAFError.missingMediaData }
        var offset = body + 8

        let dataOffset: Int64? = flags & 0x000001 != 0
            ? Int64(try reader.readInt32BE(at: offset)) : nil
        if flags & 0x000001 != 0 { offset += 4 }
        let firstFlags: UInt32? = flags & 0x000004 != 0
            ? try reader.readUInt32BE(at: offset) : nil
        if flags & 0x000004 != 0 { offset += 4 }

        var durations: [UInt32?] = []
        var sizes: [UInt32?] = []
        var sync: [Bool?] = []
        var cts: [Int32] = []
        for _ in 0..<sampleCount {
            if flags & 0x000100 != 0 {
                durations.append(try reader.readUInt32BE(at: offset))
                offset += 4
            } else {
                durations.append(nil)
            }
            if flags & 0x000200 != 0 {
                sizes.append(try reader.readUInt32BE(at: offset))
                offset += 4
            } else {
                sizes.append(nil)
            }
            if flags & 0x000400 != 0 {
                sync.append(try reader.readUInt32BE(at: offset) & 0x10000 == 0)
                offset += 4
            } else {
                sync.append(nil)
            }
            if flags & 0x000800 != 0 {
                cts.append(try reader.readInt32BE(at: offset))
                offset += 4
            } else {
                cts.append(0)
            }
        }
        if let firstFlags, !sync.isEmpty {
            sync[0] = firstFlags & 0x10000 == 0
        }
        return TRUN(
            dataOffset: dataOffset,
            firstSampleFlags: firstFlags,
            durations: durations,
            sizes: sizes,
            sync: sync,
            cts: cts
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
