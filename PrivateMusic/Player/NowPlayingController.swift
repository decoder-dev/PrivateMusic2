import MediaPlayer
import UIKit

@MainActor
final class NowPlayingController {
    private let center = MPNowPlayingInfoCenter.default()
    private var artworkTask: Task<Void, Never>?

    func update(
        track: Track,
        elapsedTime: TimeInterval,
        rate: Float,
        queueCount: Int,
        queueIndex: Int
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
            MPNowPlayingInfoPropertyServiceIdentifier: "Private Music",
            MPNowPlayingInfoPropertyPlaybackQueueCount: max(queueCount, 1),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: min(
                max(queueIndex, 0),
                max(queueCount - 1, 0)
            )
        ]
        if let albumTitle = track.albumTitle, !albumTitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }

        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused

        artworkTask?.cancel()
        guard let artworkURL = track.artworkURL else {
            return
        }
        artworkTask = Task {
            // Prefer the shared artwork cache — neighbor prefetch usually
            // already warmed the URL — instead of an ephemeral re-download.
            await ArtworkImageCache.shared.prefetch(
                url: artworkURL,
                maxPixelSize: NowPlayingArtworkPolicy.maxPixelSize
            )
            guard !Task.isCancelled,
                  let image = ArtworkImageCache.shared.image(
                    for: artworkURL,
                    maxPixelSize: NowPlayingArtworkPolicy.maxPixelSize
                  ) else {
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }
            guard center.nowPlayingInfo?[
                MPNowPlayingInfoPropertyExternalContentIdentifier
            ] as? String == track.id else {
                return
            }
            var refreshed = center.nowPlayingInfo ?? info
            refreshed[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = refreshed
        }
    }

    func updatePlayback(elapsedTime: TimeInterval, rate: Float) {
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused
    }

    func updateQueue(count: Int, index: Int) {
        guard var info = center.nowPlayingInfo, count > 0 else { return }
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = min(
            max(index, 0),
            count - 1
        )
        center.nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

enum NowPlayingArtworkPolicy {
    static let maxPixelSize: CGFloat = 600
}
