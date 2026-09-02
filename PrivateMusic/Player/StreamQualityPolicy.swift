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

/// Whether the `…/HASH/index.m3u8` → `…/HASH.mp3` rewrite is still worth
/// trying, and whether asking VK for a fresh payload is still worth a
/// request.
///
/// Both are guesses, and a device log showed what they cost when the answer
/// is always no. Over three days and 52 tracks, every single load went out
/// against a rewritten URL that answered 404, fell back to the original
/// playlist, and played — one dead request per track on a metered cellular
/// link, followed by one `audio.getById` per track that came back HLS again.
/// Fifty-two error lines for a fallback that always worked.
///
/// `AudioPlayer` already drew the right conclusion, but only for the track
/// in hand: `playbackURLStrategy` is keyed to a track id and resets on the
/// next one, so the same lesson was relearned from scratch all night. These
/// two questions keep it for the session instead.
enum ProgressiveUpgradePolicy {
    /// How many times in a row a refresh may answer "still HLS" before the
    /// hunt for a progressive URL is called off. Three is enough to tell a
    /// CDN that does not serve MP3 from one that happened to be asked at a
    /// bad moment.
    static let hlsRefreshPatience = 3

    /// The CDN a stream URL belongs to, ignoring the shard. VK spreads
    /// audio across `cs9-4v4`, `psv4` and dozens more names under the same
    /// two domains, and they all answer the rewrite alike — keying on the
    /// full host would relearn the same 404 on every shard.
    static func cdnKey(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    static func allowsUpgrade(from url: URL, refusedCDNs: Set<String>) -> Bool {
        guard let key = cdnKey(for: url) else { return true }
        return !refusedCDNs.contains(key)
    }

    /// Only a missing file teaches anything. A timeout, a lost connection or
    /// a roaming block say nothing about whether the CDN keeps an MP3 beside
    /// the playlist, and remembering one would disable the upgrade for the
    /// rest of the session over a bad minute in a tunnel.
    static func refusalIsConclusive(_ error: Error?) -> Bool {
        // AVFoundation usually surfaces the URL error as-is, but wraps it
        // when the failure arrives through an asset load.
        var candidate = error
        for _ in 0...maximumUnderlyingErrorDepth {
            guard let current = candidate else { return false }
            if let urlError = current as? URLError {
                return urlError.code == .fileDoesNotExist
            }
            candidate = (current as NSError)
                .userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }

    private static let maximumUnderlyingErrorDepth = 4

    /// A refresh that came back with the same kind of URL it was asked to
    /// replace taught nothing; one that produced a progressive file means
    /// the hunt works here and the budget starts over.
    static func hlsRefreshAttemptsAfter(
        previous: Int,
        refreshedURL: URL?
    ) -> Int {
        guard let refreshedURL else { return previous }
        return StreamQualityPolicy.isHLSStream(refreshedURL)
            ? previous + 1
            : 0
    }

    static func shouldKeepHuntingForProgressive(
        hlsOnlyRefreshes: Int
    ) -> Bool {
        hlsOnlyRefreshes < hlsRefreshPatience
    }
}
