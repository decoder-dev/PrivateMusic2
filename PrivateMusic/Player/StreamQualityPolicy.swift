import Foundation

/// Live playback quality hints for AVPlayer.
///
/// VK streams are typically progressive MP3 (≤ ~320 kbps) or HLS. There is
/// no reliable FLAC surface. When HQ is preferred we leave the peak bitrate
/// uncapped so adaptive HLS can climb; otherwise we cap to save data.
enum StreamQualityPolicy {
    /// Bits/sec. `0` means «no preferred limit» (AVFoundation default for HQ).
    static func preferredPeakBitRate(preferHighQuality: Bool) -> Double {
        preferHighQuality ? 0 : 160_000
    }

    /// When two copies of the same logical audio appear, keep the HQ one.
    static func preferredDuplicate(
        existing: Track,
        candidate: Track
    ) -> Track {
        if candidate.isHQ, !existing.isHQ { return candidate }
        return existing
    }
}
