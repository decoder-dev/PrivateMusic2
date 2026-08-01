import AVFoundation
import CoreMedia
import Foundation
@testable import PrivateMusic

/// Real CMAF fixture produced by AVAssetWriter: a short synthetic AAC sine
/// written as fragmented MP4 and sliced into init + media fragments.
/// This replaces the previous hand-patched moov/stbl that AVAssetReader
/// rejected.
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
        let seconds = 0.2
        let frameCount = Int(sampleRate * seconds)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // CMAF fragmented MP4 requires the profile hint BEFORE startWriting:
        writer.outputFileTypeProfile = .mpeg4CMAFCompliant
        writer.shouldOptimizeForNetworkUse = false

        // The input provides raw PCM; outputSettings tell the writer to
        // encode to AAC inside a CMAF-compliant .mp4 container.
        let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        var asbd = pcmFormat.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let sourceFormat = formatDescription else {
            throw FixtureError.audioFormat
        }

        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: sourceFormat
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureError.writerSetup }
        writer.add(input)

        guard writer.startWriting() else { throw FixtureError.writerStart }
        writer.startSession(atSourceTime: CMTime.zero)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let phaseStep = 2.0 * Double.pi * 440.0 / sampleRate
        for channel in 0..<2 {
            if let data = buffer.floatChannelData?[channel] {
                for frame in 0..<frameCount {
                    data[frame] = Float(sin(phaseStep * Double(frame)) * 0.2)
                }
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: CMTimeValue(frameCount),
                timescale: CMTimeScale(sampleRate)
            ),
            presentationTimeStamp: CMTime(
                value: 0,
                timescale: CMTimeScale(sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: sourceFormat,
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

        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard input.append(sampleBuffer) else {
            throw FixtureError.append
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 15) == .success,
              writer.status == .completed,
              writer.error == nil else {
            throw FixtureError.finish
        }

        let data = try Data(contentsOf: outputURL)
        return try split(data)
    }

    /// Splits the writer-produced fragmented MP4 into
    /// `ftyp/moov` initialization data and per-fragment `moof/mdat` bytes.
    private static func split(_ data: Data) throws -> Bundle {
        let reader = ISOBoxReader(data)
        let boxes = try reader.boxes()
        var moovBox: ISOBoxReader.ISOBox?
        var moovsAndFragments: [(moof: ISOBoxReader.ISOBox, mdat: ISOBoxReader.ISOBox)] = []
        for box in boxes {
            if box.type == "moov" {
                moovBox = box
            } else if box.type == "moof" {
                guard let mdat = try reader.child(
                    "mdat",
                    siblingAfter: box,
                    in: data
                ) else { continue }
                moovsAndFragments.append((box, mdat))
            }
        }
        guard let moov = moovBox, !moovsAndFragments.isEmpty else {
            throw FixtureError.missingInitialization
        }

        var initialization = data.subdata(in: 0..<moov.range.upperBound)
        // CMAF sometimes prepends a 'styp' box before each moof: strip it
        // if present so the initializer truly only contains header bytes.
        if let styp = boxes.first(where: { $0.type == "styp" }),
           styp.range.lowerBound == moov.range.upperBound {
            initialization = data.subdata(in: 0..<moov.range.upperBound + styp.range.count)
        }
        let fragments = moovsAndFragments.map {
            data.subdata(in: $0.moof.range) + data.subdata(in: $0.mdat.range)
        }
        return Bundle(initialization: initialization, fragments: fragments)
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
    }
}

private extension ISOBoxReader {
    func child(
        _ type: String,
        siblingAfter sibling: ISOBox,
        in data: Data
    ) throws -> ISOBox? {
        let nextOffset = sibling.range.upperBound
        guard nextOffset + 8 <= data.count else { return nil }
        let size32 = try readUInt32BE(at: nextOffset)
        guard size32 >= 8, nextOffset + Int(size32) <= data.count else {
            return nil
        }
        let nextType = String(
            bytes: data.subdata(in: (nextOffset + 4)..<(nextOffset + 8)),
            encoding: .ascii
        )
        guard nextType == type else { return nil }
        return ISOBox(
            type: type,
            range: nextOffset..<(nextOffset + Int(size32)),
            headerSize: 8
        )
    }
}
