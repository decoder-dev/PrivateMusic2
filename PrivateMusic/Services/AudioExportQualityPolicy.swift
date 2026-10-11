import Foundation

/// Export preserves the source rate and channels. A fallback transcode
/// gets 160kbps per channel; playback's data-saving choices do not apply.
enum AudioExportQualityPolicy {
    static func sampleRate(_ source: Double?) -> Double {
        guard let source, source.isFinite, source >= 8_000, source <= 192_000 else {
            return 44_100
        }
        return source
    }

    static func channelCount(_ source: UInt32?) -> UInt32 {
        min(8, max(1, source ?? 2))
    }

    static func bitRate(channels: UInt32) -> Int {
        Int(channelCount(channels)) * 160_000
    }
}
