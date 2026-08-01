import AVFoundation
import CoreMedia
import Foundation

/// Deterministic, non-copyrighted audio fixture for HLS tests: 0.2 seconds of
/// silence encoded as AAC inside a fragmented MP4.
///
/// AVAssetWriter is not guaranteed to emit `moof`/`mdat` fragments for
/// audio-only output even with a `movieFragmentInterval`, so the fixture
/// writes a plain `.m4a` and then splits the samples from the `moov` sample
/// table into two CMAF fragments built by hand. The initialization section is
/// `ftyp` plus a patched `moov` with empty sample tables and a `mvex`/`trex`
/// declaration, exactly like a real HLS fragmented stream; the segments are
/// two `moof`/`mdat` pairs. `CMAFAudioDemuxer` parses these boxes and the
/// end-to-end tests assert a playable M4A via the AAC passthrough writer.
enum FragmentedMP4Fixture {
    struct Bundle {
        let initialization: Data
        let fragments: [Data]
    }

    static func make() throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FragmentedMP4Fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("fixture.mp4")

        let sampleRate = 44_100.0
        let frameCount = 8_820 // 0.2 s at 44.1 kHz
        let channels: UInt32 = 2

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(channels) {
            if let samples = buffer.floatChannelData?[channel] {
                memset(samples, 0, frameCount * 4)
            }
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw FixtureError.audioFormat
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw FixtureError.sampleBuffer
        }
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            bufferList: buffer.mutableAudioBufferList
        )
        guard attachStatus == noErr else {
            throw FixtureError.audioBufferList
        }
        guard CMSampleBufferSetDataReady(sampleBuffer) == noErr else {
            throw FixtureError.sampleBuffer
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw FixtureError.writerSetup
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerStart
        }
        writer.startSession(atSourceTime: .zero)
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard input.append(sampleBuffer) else {
            throw FixtureError.append
        }
        input.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        var writerError: Error?
        writer.finishWriting {
            writerError = writer.error
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 15) == .success,
              writer.status == .completed,
              writerError == nil else {
            throw FixtureError.finish
        }

        let data = try Data(contentsOf: outputURL)
        let boxes = topLevelBoxes(in: data)
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" })?.range,
              let moov = boxes.first(where: { $0.type == "moov" })?.range,
              let mdat = boxes.first(where: { $0.type == "mdat" })?.range else {
            throw FixtureError.missingInitialization
        }

        let trackID = try Self.trackID(in: data, moov: moov)
        let sizes = try Self.sampleSizes(in: data, moov: moov)
        var durations = try Self.sampleDurations(in: data, moov: moov)
        guard !sizes.isEmpty else {
            throw FixtureError.missingSamples
        }
        if durations.count == 1 {
            durations = Array(repeating: durations[0], count: sizes.count)
        }
        guard durations.count == sizes.count else {
            throw FixtureError.invalidBox
        }
        let initialization = try Self.initialization(
            from: data,
            ftyp: ftyp,
            moov: moov,
            trackID: trackID
        )

        let payload = data.subdata(in: mdat.lowerBound + 8..<mdat.upperBound)
        let splitIndex = (sizes.count + 1) / 2
        var fragments: [Data] = []
        var payloadOffset = 0
        var baseMediaDecodeTime: UInt64 = 0
        let parts = sizes.count > 1 ? [0..<splitIndex, splitIndex..<sizes.count] : [0..<sizes.count]
        for part in parts {
            var chunk = Data()
            var samples: [(duration: UInt32, size: UInt32)] = []
            for index in part {
                let size = Int(sizes[index])
                chunk.append(payload.subdata(in: payloadOffset..<(payloadOffset + size)))
                payloadOffset += size
                samples.append((duration: durations[index], size: sizes[index]))
            }
            fragments.append(
                Self.fragment(
                    trackID: trackID,
                    baseMediaDecodeTime: baseMediaDecodeTime,
                    samples: samples,
                    payload: chunk
                )
            )
            baseMediaDecodeTime += samples.reduce(0) { $0 + UInt64($1.duration) }
        }
        guard !fragments.isEmpty else {
            throw FixtureError.missingSamples
        }
        return Bundle(initialization: initialization, fragments: fragments)
    }

    /// Rebuilds the `moov` as a CMAF initialization section: movie and track
    /// durations are zeroed and the sample tables (`stsz`, `stts`, `stco`,
    /// `stsc`) are rebuilt from scratch with empty entries so all samples are
    /// read from `moof` fragments, then a `mvex`/`trex` box is appended.
    private static func initialization(
        from data: Data,
        ftyp: Range<Int>,
        moov: Range<Int>,
        trackID: UInt32
    ) throws -> Data {
        let moovChildren = children(of: moov, in: data)

        // Build new mvhd with zero duration.
        var mvhdPayload = Data()
        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            let version = data[mvhd.range.lowerBound + 8]
            mvhdPayload = data.subdata(in: mvhd.range.lowerBound + 8..<mvhd.range.upperBound)
            let durationOffset = version == 1 ? 24 : 16
            mvhdPayload.replaceSubrange(
                durationOffset..<durationOffset + 4,
                with: u32(0)
            )
        }

        // Build new trak with zero tkhd duration and rebuilt stbl.
        guard let trak = moovChildren.first(where: { $0.type == "trak" }) else {
            throw FixtureError.invalidBox
        }
        let trakChildren = children(of: trak.range, in: data)
        var newTrakPayload = Data()
        for child in trakChildren {
            if child.type == "tkhd" {
                let version = data[child.range.lowerBound + 8]
                var tkhdPayload = data.subdata(in: child.range.lowerBound + 8..<child.range.upperBound)
                let durationOffset = version == 1 ? 28 : 20
                tkhdPayload.replaceSubrange(
                    durationOffset..<durationOffset + 4,
                    with: u32(0)
                )
                newTrakPayload.append(box("tkhd", payload: tkhdPayload))
            } else if child.type == "mdia" {
                let mdiaChildren = children(of: child.range, in: data)
                var newMdiaPayload = Data()
                for mdiaChild in mdiaChildren {
                    if mdiaChild.type == "minf" {
                        let minfChildren = children(of: mdiaChild.range, in: data)
                        var newMinfPayload = Data()
                        for minfChild in minfChildren {
                            if minfChild.type == "stbl" {
                                let stblChildren = children(of: minfChild.range, in: data)
                                var newStblPayload = Data()
                                if let stsd = stblChildren.first(where: { $0.type == "stsd" }) {
                                    newStblPayload.append(data.subdata(in: stsd.range))
                                }
                                newStblPayload.append(box("stts", payload: u32(0) + u32(0)))
                                newStblPayload.append(box("stco", payload: u32(0) + u32(0)))
                                newStblPayload.append(box("stsc", payload: u32(0) + u32(0)))
                                newStblPayload.append(box("stsz", payload: u32(0) + u32(0) + u32(0)))
                                for stblChild in stblChildren {
                                    if !["stsd", "stts", "stco", "stsc", "stsz"].contains(stblChild.type) {
                                        newStblPayload.append(data.subdata(in: stblChild.range))
                                    }
                                }
                                newMinfPayload.append(box("stbl", payload: newStblPayload))
                            } else {
                                newMinfPayload.append(data.subdata(in: minfChild.range))
                            }
                        }
                        newMdiaPayload.append(box("minf", payload: newMinfPayload))
                    } else {
                        newMdiaPayload.append(data.subdata(in: mdiaChild.range))
                    }
                }
                newTrakPayload.append(box("mdia", payload: newMdiaPayload))
            } else {
                newTrakPayload.append(data.subdata(in: child.range))
            }
        }

        // Build new moov.
        var newMoovPayload = Data()
        for child in moovChildren {
            if child.type == "mvhd" {
                newMoovPayload.append(box("mvhd", payload: mvhdPayload))
            } else if child.type == "trak" {
                newMoovPayload.append(box("trak", payload: newTrakPayload))
            } else {
                newMoovPayload.append(data.subdata(in: child.range))
            }
        }

        let trex = box(
            "trex",
            payload: u32(0) + u32(trackID) + u32(1) + u32(0) + u32(0) + u32(0)
        )
        newMoovPayload.append(box("mvex", payload: trex))
        return data.subdata(in: ftyp) + box("moov", payload: newMoovPayload)
    }

    private static func trackID(in data: Data, moov: Range<Int>) throws -> UInt32 {
        let moovChildren = children(of: moov, in: data)
        guard let trak = moovChildren.first(where: { $0.type == "trak" }),
              let tkhd = children(of: trak.range, in: data).first(where: { $0.type == "tkhd" }),
              let mdia = children(of: trak.range, in: data).first(where: { $0.type == "mdia" }),
              let mdhd = children(of: mdia.range, in: data).first(where: { $0.type == "mdhd" }) else {
            throw FixtureError.invalidBox
        }
        let body = tkhd.range.lowerBound + 8
        let version = data[body]
        return readUInt32(body + (version == 1 ? 20 : 12), in: data)
    }

    private static func sampleSizes(in data: Data, moov: Range<Int>) throws -> [UInt32] {
        let stbl = try sampleTableBoxes(in: data, moov: moov)
        guard let stsz = stbl.first(where: { $0.type == "stsz" }) else {
            throw FixtureError.invalidBox
        }
        let body = stsz.range.lowerBound + 8
        let uniformSize = readUInt32(body + 4, in: data)
        let count = Int(readUInt32(body + 8, in: data))
        if uniformSize != 0 {
            return Array(repeating: uniformSize, count: count)
        }
        var sizes: [UInt32] = []
        for index in 0..<count {
            guard body + 12 + index * 4 + 4 <= stsz.range.upperBound else { break }
            sizes.append(readUInt32(body + 12 + index * 4, in: data))
        }
        return sizes
    }

    private static func sampleDurations(in data: Data, moov: Range<Int>) throws -> [UInt32] {
        let stbl = try sampleTableBoxes(in: data, moov: moov)
        guard let stts = stbl.first(where: { $0.type == "stts" }) else {
            throw FixtureError.invalidBox
        }
        let body = stts.range.lowerBound + 8
        let entryCount = Int(readUInt32(body + 4, in: data))
        var durations: [UInt32] = []
        for index in 0..<entryCount {
            let entryOffset = body + 8 + index * 8
            guard entryOffset + 8 <= stts.range.upperBound else { break }
            let count = Int(readUInt32(entryOffset, in: data))
            let delta = readUInt32(entryOffset + 4, in: data)
            durations.append(contentsOf: Array(repeating: delta, count: count))
        }
        return durations
    }

    private static func sampleTableBoxes(
        in data: Data,
        moov: Range<Int>
    ) throws -> [BoxInfo] {
        let moovChildren = children(of: moov, in: data)
        guard let trak = moovChildren.first(where: { $0.type == "trak" }),
              let mdia = children(of: trak.range, in: data).first(where: { $0.type == "mdia" }),
              let minf = children(of: mdia.range, in: data).first(where: { $0.type == "minf" }),
              let stbl = children(of: minf.range, in: data).first(where: { $0.type == "stbl" }) else {
            throw FixtureError.invalidBox
        }
        return children(of: stbl.range, in: data)
    }

    private static func fragment(
        trackID: UInt32,
        baseMediaDecodeTime: UInt64,
        samples: [(duration: UInt32, size: UInt32)],
        payload: Data
    ) -> Data {
        let mfhd = box("mfhd", payload: u32(0))
        let tfhd = box("tfhd", payload: u32(0x020000) + u32(trackID))
        let tfdt = box("tfdt", payload: u32(0x01000000) + u64(baseMediaDecodeTime))
        var entries = Data()
        for sample in samples {
            entries.append(u32(sample.duration))
            entries.append(u32(sample.size))
        }
        let trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200
        let placeholder = box(
            "trun",
            payload: u32(trunFlags) + u32(UInt32(samples.count)) + u32(0) + entries
        )
        let moofWithPlaceholder = box(
            "moof",
            payload: mfhd + box("traf", payload: tfhd + tfdt + placeholder)
        )
        let dataOffset = UInt32(moofWithPlaceholder.count + 8)
        let trun = box(
            "trun",
            payload: u32(trunFlags) + u32(UInt32(samples.count)) + u32(dataOffset) + entries
        )
        let moof = box(
            "moof",
            payload: mfhd + box("traf", payload: tfhd + tfdt + trun)
        )
        return moof + box("mdat", payload: payload)
    }

    private static func topLevelBoxes(
        in data: Data
    ) -> [(type: String, range: Range<Int>)] {
        var boxes: [(String, Range<Int>)] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = readUInt32(offset, in: data)
            let type = String(
                data: data.subdata(in: offset + 4..<offset + 8),
                encoding: .ascii
            ) ?? ""
            let size: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                let size64 = readUInt64(offset + 8, in: data)
                size = size64 > Int.max ? data.count - offset : Int(size64)
            } else if size32 == 0 {
                size = data.count - offset
            } else {
                size = Int(size32)
            }
            guard size >= 8, offset + size <= data.count else { break }
            boxes.append((type, offset..<(offset + size)))
            offset += size
        }
        return boxes
    }

    private static func children(of range: Range<Int>, in data: Data) -> [BoxInfo] {
        var boxes: [BoxInfo] = []
        var offset = range.lowerBound + 8
        while offset + 8 <= range.upperBound {
            let size = Int(readUInt32(offset, in: data))
            guard size >= 8, offset + size <= range.upperBound else { break }
            boxes.append(
                BoxInfo(
                    type: String(
                        data: data.subdata(in: offset + 4..<offset + 8),
                        encoding: .ascii
                    ) ?? "",
                    range: offset..<(offset + size)
                )
            )
            offset += size
        }
        return boxes
    }

    private struct BoxInfo {
        let type: String
        let range: Range<Int>
    }

    private static func u32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func u64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func box(_ type: String, payload: Data) -> Data {
        var data = u32(UInt32(payload.count + 8))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private static func readUInt32(_ offset: Int, in data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(
                fromByteOffset: offset,
                as: UInt32.self
            ).bigEndian
        }
    }

    private static func readUInt64(_ offset: Int, in data: Data) -> UInt64 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(
                fromByteOffset: offset,
                as: UInt64.self
            ).bigEndian
        }
    }

    private enum FixtureError: Error {
        case audioFormat
        case sampleBuffer
        case audioBufferList
        case writerSetup
        case writerStart
        case append
        case finish
        case missingInitialization
        case missingSamples
        case invalidBox
    }
}
