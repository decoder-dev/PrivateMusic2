import AudioToolbox
import Foundation

/// Changes the ADTS container to M4A without decoding or re-encoding AAC.
/// Memory stays bounded to one packet batch, including long recordings.
enum AACPacketRemuxer {
    struct RemuxError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "AAC remux \(operation): \(status)" }
    }

    static func remux(source: URL, destination: URL) throws {
        try Task.checkCancellation()
        var sourceFile: AudioFileID?
        try check(AudioFileOpenURL(source as CFURL, .readPermission, 0, &sourceFile), "open")
        guard let sourceFile else { throw RemuxError(operation: "source", status: -1) }
        defer { AudioFileClose(sourceFile) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(sourceFile, kAudioFilePropertyDataFormat,
                                       &formatSize, &format), "format")
        guard format.mFormatID == kAudioFormatMPEG4AAC,
              format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mChannelsPerFrame > 0 else {
            throw RemuxError(operation: "unsupported format", status: -1)
        }

        var destinationFile: AudioFileID?
        try check(AudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType,
                                        &format, .eraseFile, &destinationFile), "create")
        guard let destinationFile else { throw RemuxError(operation: "destination", status: -1) }
        var closed = false
        var completed = false
        defer {
            if !closed { AudioFileClose(destinationFile) }
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        // AAC decoder configuration must precede packet writes (Apple's
        // kAudioFilePropertyMagicCookieData contract).
        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(sourceFile, kAudioFilePropertyMagicCookieData,
                                    &cookieSize, nil) == noErr, cookieSize > 0 {
            guard cookieSize <= 1_048_576 else {
                throw RemuxError(operation: "cookie size", status: -1)
            }
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            try cookie.withUnsafeMutableBytes { bytes in
                try check(AudioFileGetProperty(sourceFile, kAudioFilePropertyMagicCookieData,
                                               &cookieSize, bytes.baseAddress!), "read cookie")
                try check(AudioFileSetProperty(destinationFile, kAudioFilePropertyMagicCookieData,
                                               cookieSize, bytes.baseAddress!), "write cookie")
            }
        }

        var maximumPacketSize: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioFileGetProperty(sourceFile, kAudioFilePropertyPacketSizeUpperBound,
                                       &propertySize, &maximumPacketSize), "packet size")
        guard maximumPacketSize > 0, maximumPacketSize <= 1_048_576 else {
            throw RemuxError(operation: "packet size bounds", status: -1)
        }
        let capacity = max(65_536, Int(maximumPacketSize))
        let packetsPerBatch = min(512, capacity / Int(maximumPacketSize))
        var buffer = [UInt8](repeating: 0, count: capacity)
        var descriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(), count: packetsPerBatch
        )
        var packetPosition: Int64 = 0
        while true {
            try Task.checkCancellation()
            var byteCount = UInt32(capacity)
            var packetCount = UInt32(packetsPerBatch)
            try buffer.withUnsafeMutableBytes { bytes in
                try descriptions.withUnsafeMutableBufferPointer { packets in
                    let status = AudioFileReadPacketData(sourceFile, false, &byteCount,
                                                        packets.baseAddress, packetPosition,
                                                        &packetCount, bytes.baseAddress)
                    guard status == noErr || status == kAudioFileEndOfFileError else {
                        throw RemuxError(operation: "read packets", status: status)
                    }
                    guard packetCount > 0 else { return }
                    var written = packetCount
                    try check(AudioFileWritePackets(destinationFile, false, byteCount,
                                                    packets.baseAddress, packetPosition,
                                                    &written, bytes.baseAddress!), "write packets")
                    guard written == packetCount else {
                        throw RemuxError(operation: "partial write", status: -1)
                    }
                }
            }
            guard packetCount > 0 else { break }
            packetPosition += Int64(packetCount)
        }
        guard packetPosition > 0 else { throw RemuxError(operation: "empty audio", status: -1) }
        try Task.checkCancellation()
        let closeStatus = AudioFileClose(destinationFile)
        closed = true
        try check(closeStatus, "finalize")
        completed = true
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw RemuxError(operation: operation, status: status) }
    }
}
