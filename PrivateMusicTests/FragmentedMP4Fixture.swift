import AVFoundation
import CoreMedia
import Foundation

/// Real CMAF fixture produced by AVAssetWriter: a short synthetic AAC sine
/// written as fragmented MP4 and sliced into init + two media fragments.
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
        let seconds = 0.4
        let frameCount = Int(sampleRate * seconds)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.outputFileTypeProfile = .mpeg4CMAFCompliant

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        var asbd = format.streamDescription.pointee
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
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: Int(sampleRate),
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ],
            sourceFormatHint: sourceFormat
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureError.writerSetup }
        writer.add(input)

        guard writer.startWriting() else { throw FixtureError.writerStart }
        writer.startSession(atSourceTime: .zero)

        // Feed PCM 440 Hz stereo sine in chunks so the writer fragments a
        // valid CMAF stream with at least two moofs.
        let chunkFrames = 4410 // 100 ms worth
        var offset = 0
        var timestamp = CMTime.zero
        while offset < frameCount {
            let framesToWrite = min(chunkFrames, frameCount - offset)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesToWrite)
            )!
            buffer.frameLength = AVAudioFrameCount(framesToWrite)
            let phaseStep = 2.0 * Double.pi * 440.0 / sampleRate
            for channel in 0..<2 {
                if let data = buffer.floatChannelData?[channel] {
                    for frame in 0..<framesToWrite {
                        let phase = phaseStep * Double(offset + frame)
                        data[frame] = Float(sin(phase) * 0.2)
                    }
                }
            }

            var timing = CMSampleTimingInfo(
                duration: CMTime(
                    value: CMTimeValue(framesToWrite),
                    timescale: CMTimeScale(sampleRate)
                ),
                presentationTimeStamp: timestamp,
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
                sampleCount: framesToWrite,
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
            offset += framesToWrite
            timestamp = CMTimeAdd(
                timestamp,
                CMTime(
                    value: CMTimeValue(framesToWrite),
                    timescale: CMTimeScale(sampleRate)
                )
            )
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
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw FixtureError.missingInitialization
        }
        var fragments: [Data] = []
        var moofStart = moov.range.upperBound
        while moofStart < data.count,
              let moof = try reader.parseBoxIfPossible(at: moofStart),
              moof.type == "moof" {
            guard let mdat = try reader.child(
                "mdat",
                siblingAfter: moof,
                in: data
            ) else {
                break
            }
            fragments.append(
                data.subdata(in: moof.range) + data.subdata(in: mdat.range)
            )
            moofStart = mdat.range.upperBound
        }
        guard !fragments.isEmpty else { throw FixtureError.missingSamples }

        let initializationBoxes: [ISOBoxReader.ISOBox] = boxes.filter {
            $0.range.lowerBound <= moov.range.upperBound
        }
        let initialization = initializationBoxes.map {
            data.subdata(in: $0.range)
        }.reduce(Data(), +)
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
    func parseBoxIfPossible(at offset: Int) throws -> ISOBox? {
        guard offset + 8 <= data.count else { return nil }
        let size32 = try readUInt32BE(at: offset)
        guard size32 >= 8, offset + Int(size32) <= data.count else {
            return nil
        }
        return ISOBox(
            type: String(
                bytes: data.subdata(in: (offset + 4)..<(offset + 8)),
                encoding: .ascii
            ) ?? "",
            range: offset..<(offset + Int(size32)),
            headerSize: 8
        )
    }

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
