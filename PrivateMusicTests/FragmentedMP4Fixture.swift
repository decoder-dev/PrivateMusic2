import AVFoundation
import CoreMedia
import Foundation

/// Deterministic, non-copyrighted audio fixture for HLS tests: 0.2 seconds of
/// silence encoded as AAC inside a fragmented MP4.
///
/// The output of `AVAssetWriter` with a `movieFragmentInterval` is a standard
/// CMAF-compatible stream: an initialization section (`ftyp` + `moov`) followed
/// by `moof`/`mdat` fragments. The fixture is produced at runtime (not stored)
/// and split into exactly those pieces, so tests can serve them as an
/// `#EXT-X-MAP` playlist.
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

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw FixtureError.sampleBuffer
        }
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            audioBufferList: buffer.mutableAudioBufferList
        )
        guard attachStatus == noErr else {
            throw FixtureError.audioBufferList
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 10)
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
              let moov = boxes.first(where: { $0.type == "moov" })?.range else {
            throw FixtureError.missingInitialization
        }
        let initialization = data.subdata(in: ftyp) + data.subdata(in: moov)

        var fragments: [Data] = []
        var index = 0
        while index < boxes.count {
            guard boxes[index].type == "moof" else {
                index += 1
                continue
            }
            let moofRange = boxes[index].range
            guard index + 1 < boxes.count, boxes[index + 1].type == "mdat" else {
                index += 1
                continue
            }
            let mdatRange = boxes[index + 1].range
            fragments.append(
                data.subdata(in: moofRange) + data.subdata(in: mdatRange)
            )
            index += 2
        }
        guard !fragments.isEmpty else {
            throw FixtureError.noFragments
        }
        return Bundle(initialization: initialization, fragments: fragments)
    }

    private static func topLevelBoxes(
        in data: Data
    ) -> [(type: String, range: Range<Int>)] {
        var boxes: [(String, Range<Int>)] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = data.withUnsafeBytes { raw in
                raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                ).bigEndian
            }
            let type = String(
                data: data.subdata(in: offset + 4..<offset + 8),
                encoding: .ascii
            ) ?? ""
            let size: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                let size64 = data.withUnsafeBytes { raw in
                    raw.loadUnaligned(
                        fromByteOffset: offset + 8,
                        as: UInt64.self
                    ).bigEndian
                }
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

    private enum FixtureError: Error {
        case audioFormat
        case sampleBuffer
        case audioBufferList
        case writerSetup
        case writerStart
        case append
        case finish
        case missingInitialization
        case noFragments
    }
}
