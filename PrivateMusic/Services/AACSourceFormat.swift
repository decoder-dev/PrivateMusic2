import AudioToolbox
import Foundation

/// Resolve the richest decoder description from the source cookie. In
/// particular HE-AAC must retain SBR/PS, rather than being labelled AAC-LC.
enum AACSourceFormat {
    static func resolve(cookie: Data) throws -> AudioStreamBasicDescription {
        try cookie.withUnsafeBytes { bytes in
            guard !cookie.isEmpty, cookie.count <= 1_048_576, let pointer = bytes.baseAddress else {
                throw AACPacketRemuxer.RemuxError(operation: "AAC cookie bounds", status: -1)
            }
            var base = AudioStreamBasicDescription()
            base.mFormatID = kAudioFormatMPEG4AAC
            var info = AudioFormatInfo(
                mASBD: base, mMagicCookie: pointer,
                mMagicCookieSize: UInt32(cookie.count)
            )
            let infoSize = UInt32(MemoryLayout<AudioFormatInfo>.size)
            var listSize: UInt32 = 0
            let listStatus = AudioFormatGetPropertyInfo(
                kAudioFormatProperty_FormatList, infoSize, &info, &listSize
            )
            let stride = MemoryLayout<AudioFormatListItem>.stride
            if listStatus == noErr, listSize >= stride, listSize <= 64 * stride {
                var formats = [AudioFormatListItem](
                    repeating: AudioFormatListItem(), count: Int(listSize) / stride
                )
                let status = formats.withUnsafeMutableBytes {
                    AudioFormatGetProperty(
                        kAudioFormatProperty_FormatList, infoSize, &info, &listSize, $0.baseAddress!
                    )
                }
                if status == noErr, let richest = formats.first, isValid(richest.mASBD) {
                    return richest.mASBD
                }
            }
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo, UInt32(cookie.count), bytes.baseAddress, &size, &base
            )
            guard status == noErr, isValid(base) else {
                throw AACPacketRemuxer.RemuxError(operation: "AAC source format", status: status)
            }
            return base
        }
    }

    private static func isValid(_ format: AudioStreamBasicDescription) -> Bool {
        format.mSampleRate.isFinite && format.mSampleRate > 0
            && format.mChannelsPerFrame > 0 && format.mFramesPerPacket > 0
    }
}
