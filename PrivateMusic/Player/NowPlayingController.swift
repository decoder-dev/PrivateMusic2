import MediaPlayer
import UIKit

@MainActor
final class NowPlayingController {
    private let center = MPNowPlayingInfoCenter.default()
    private let artworkSession: URLSession
    private var artworkTask: Task<Void, Never>?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        artworkSession = URLSession(configuration: configuration)
    }

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
            do {
                let (data, response) = try await artworkSession.data(
                    from: artworkURL
                )
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = UIImage(data: data) else {
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
            } catch {
                return
            }
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
