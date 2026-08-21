import Foundation

/// Live playback quality hints and VK stream URL selection.
///
/// VK streams are typically progressive MP3 (≤ ~320 kbps) or HLS. There is
/// no reliable FLAC surface. When HQ is preferred we leave the peak bitrate
/// uncapped so adaptive HLS can climb; otherwise we cap to save data.
///
/// For HLS URLs, clients such as [vk_api](https://github.com/python273/vk_api)
/// rewrite `index.m3u8` to a direct `.mp3` when possible. Progressive MP3 avoids
/// adaptive low-bitrate starts, enables on-device EQ (`MTAudioProcessingTap`),
/// and sounds fuller than a cold HLS ladder.
enum StreamQualityPolicy {
    /// Data-saver peak bitrate (bits/sec).
    static let dataSaverPeakBitRate: Double = 256_000

    /// Bits/sec. `0` means «no preferred limit» (AVFoundation default for HQ).
    static func preferredPeakBitRate(preferHighQuality: Bool) -> Double {
        preferHighQuality ? 0 : dataSaverPeakBitRate
    }

    /// When two copies of the same logical audio appear, keep the HQ one.
    static func preferredDuplicate(
        existing: Track,
        candidate: Track
    ) -> Track {
        if candidate.isHQ, !existing.isHQ { return candidate }
        return existing
    }

    /// Whether `url` points at an HLS playlist rather than a progressive file.
    static func isHLSStream(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame {
            return true
        }
        return url.absoluteString.localizedCaseInsensitiveContains("index.m3u8")
    }

    /// Derive a direct progressive MP3 URL from a VK HLS playlist when the
    /// host follows the usual `…/HASH/index.m3u8` layout.
    static func progressiveURL(from url: URL) -> URL? {
        progressiveURLFromIndexSuffix(url)
    }

    /// URL to hand to `AVPlayer` for a remote VK stream.
    ///
    /// `requiresAudioProcessing` rewrites for a reason other than quality:
    /// on-device processing needs a progressive file because a tap cannot
    /// attach to an HLS playlist. Without it the data saver silently
    /// disabled the equalizer along with the bitrate.
    static func playbackURL(
        _ url: URL,
        preferHighQuality: Bool,
        requiresAudioProcessing: Bool = false,
        allowProgressiveUpgrade: Bool = true
    ) -> URL {
        guard preferHighQuality || requiresAudioProcessing,
              allowProgressiveUpgrade else {
            return url
        }
        return progressiveURL(from: url) ?? url
    }

    /// True when playback deliberately upgraded HLS to progressive MP3.
    static func usedProgressiveUpgrade(original: URL, playback: URL) -> Bool {
        isHLSStream(original)
            && !isHLSStream(playback)
            && original != playback
    }

    /// LavaSrc / VK clients refresh `audio.getById` when the live URL is
    /// still an HLS playlist after the local m3u8→mp3 rewrite. A fresh
    /// payload sometimes carries a progressive MP3. One attempt per load
    /// and per neighbor preload — if VK still returns HLS we play or warm
    /// that instead of looping.
    static func shouldRefreshHLSBeforePlay(
        sourceURL: URL?,
        playbackURL: URL?,
        alreadyRefreshed: Bool
    ) -> Bool {
        guard !alreadyRefreshed,
              let sourceURL,
              let playbackURL else {
            return false
        }
        return isHLSStream(sourceURL) && isHLSStream(playbackURL)
    }

    // MARK: - Private

    /// psv4 and most modern VK hosts:
    /// `…/HASH/index.m3u8` → `…/HASH.mp3`
    private static func progressiveURLFromIndexSuffix(_ url: URL) -> URL? {
        var raw = url.absoluteString
        if let queryStart = raw.firstIndex(of: "?") {
            raw = String(raw[..<queryStart])
        }
        guard raw.localizedCaseInsensitiveContains("index.m3u8") else {
            return nil
        }
        guard raw.lowercased().hasSuffix("/index.m3u8") else {
            return nil
        }
        let mp3 = String(raw.dropLast("/index.m3u8".count)) + ".mp3"
        return URL.secureRemoteURL(mp3)
    }
}
