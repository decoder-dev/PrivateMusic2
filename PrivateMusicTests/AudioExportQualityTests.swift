import AudioToolbox
import AVFoundation
import XCTest
@testable import PrivateMusic

final class AudioExportQualityTests: XCTestCase {
    func testCMAFFormatRetainsHEAACExtensionRate() throws {
        let format = try AACSourceFormat.resolve(cookie: cookie(asc: [0x2b, 0x92, 0x08, 0x00]))
        XCTAssertEqual(format.mSampleRate, 44_100)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC_HE)
    }

    func testCMAFFormatResolvesAACLCFromTheSourceCookie() throws {
        let format = try AACSourceFormat.resolve(cookie: cookie(asc: [0x12, 0x10]))
        XCTAssertEqual(format.mSampleRate, 44_100)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(format.mFramesPerPacket, 1_024)
        XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC)
    }

    private func cookie(asc: [UInt8]) -> Data {
        Data([0x03, UInt8(23 + asc.count), 0x00, 0x01, 0x00,
              0x04, UInt8(15 + asc.count), 0x40, 0x15,
              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
              0x00, 0x00, 0x00, 0x00, 0x05, UInt8(asc.count)]
             + asc + [0x06, 0x01, 0x02])
    }

    func testAACRemuxPreservesEveryCompressedPacket() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aac")
        let destination = directory.appendingPathComponent("export.m4a")
        try AACAudioFixture.data.write(to: source)
        try AACPacketRemuxer.remux(source: source, destination: destination)
        let original = try readPackets(source)
        let exported = try readPackets(destination)
        XCTAssertFalse(original.packets.isEmpty)
        XCTAssertEqual(exported.packets, original.packets, "Export must not re-encode AAC")
        XCTAssertEqual(exported.rate, original.rate)
        XCTAssertEqual(exported.channels, 2)
    }

    func testM4AMetadataKeepsEveryCompressedAACPacket() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.aac")
        let destination = directory.appendingPathComponent("export.m4a")
        try AACAudioFixture.data.write(to: source)
        try AACPacketRemuxer.remux(source: source, destination: destination)
        let before = try readPackets(destination)
        let track = Track(trackID: 1, ownerID: 1, title: "Evening", artist: "Private Music",
                          duration: 1, streamURL: nil, artworkURL: nil)
        try await AudioShareEnricher().tagM4A(destination, track: track, artwork: nil)
        let after = try readPackets(destination)
        XCTAssertEqual(after.packets, before.packets)
        XCTAssertEqual(after.rate, before.rate)
        XCTAssertEqual(after.channels, before.channels)
        let metadata = try await AVURLAsset(url: destination).load(.commonMetadata)
        XCTAssertEqual(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            .first?.stringValue, "Evening")
    }

    func testInvalidAACLeavesNoExportAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("broken.aac")
        let destination = directory.appendingPathComponent("export.m4a")
        try Data("invalid audio".utf8).write(to: source)
        XCTAssertThrowsError(try AACPacketRemuxer.remux(source: source, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFallbackPreservesTheSourceRateAndChannelCount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("export.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            samples[0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.3
            samples[1][index] = Float(sin(Double(index) * 2 * .pi * 12_000 / 48_000)) * 0.3
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        try await HLSSegmentExporter().exportMovpkgToM4A(
            packageURL: source, destination: destination, fileSizeLimit: 150_000_000
        )
        let exported = try readPackets(destination)
        XCTAssertEqual(exported.rate, 48_000)
        XCTAssertEqual(exported.channels, 2)
        XCTAssertFalse(exported.packets.isEmpty)
        let decoded = try AVAudioFile(forReading: destination, commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        let decodedBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length)
        ))
        try decoded.read(into: decodedBuffer)
        let decodedSamples = try XCTUnwrap(decodedBuffer.floatChannelData)
        let count = Int(decodedBuffer.frameLength)
        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(toneAmplitude(decodedSamples[1], count: count, frequency: 12_000), 0.18,
                             "Fallback must retain high frequencies, rather than sounding muffled")
        XCTAssertLessThan(toneAmplitude(decodedSamples[0], count: count, frequency: 12_000), 0.03,
                          "Fallback must preserve stereo separation")
    }

    func testFallbackQualityDoesNotUseTheOld192KbpsCeiling() {
        XCTAssertEqual(AudioExportQualityPolicy.bitRate(channels: 2), 320_000)
        XCTAssertEqual(AudioExportQualityPolicy.sampleRate(48_000), 48_000)
        XCTAssertEqual(AudioExportQualityPolicy.sampleRate(.nan), 44_100)
        XCTAssertEqual(AudioExportQualityPolicy.channelCount(6), 6)
    }

    private func readPackets(_ url: URL) throws -> (packets: [Data], rate: Double, channels: UInt32) {
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        XCTAssertEqual(status, noErr)
        let opened = try XCTUnwrap(file)
        defer { AudioFileClose(opened) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        XCTAssertEqual(AudioFileGetProperty(opened, kAudioFilePropertyDataFormat, &size, &format), noErr)
        var packets: [Data] = []
        var position: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            var count: UInt32 = 1
            var bytes = UInt32(buffer.count)
            var description = AudioStreamPacketDescription()
            let read = buffer.withUnsafeMutableBytes {
                AudioFileReadPacketData(opened, false, &bytes, &description, position, &count, $0.baseAddress)
            }
            guard read == noErr || read == kAudioFileEndOfFileError else {
                throw AACPacketRemuxer.RemuxError(operation: "test read", status: read)
            }
            guard count > 0 else { break }
            XCTAssertEqual(read, noErr)
            packets.append(Data(buffer.prefix(Int(bytes))))
            position += 1
            guard position <= 10_000 else {
                throw AACPacketRemuxer.RemuxError(operation: "test packet limit", status: -1)
            }
        }
        return (packets, format.mSampleRate, format.mChannelsPerFrame)
    }

    private func toneAmplitude(_ samples: UnsafePointer<Float>, count: Int, frequency: Double) -> Double {
        guard count > 0 else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<count {
            let phase = Double(index) * 2 * .pi * frequency / 48_000
            real += Double(samples[index]) * cos(phase)
            imaginary += Double(samples[index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(count)
    }
}
