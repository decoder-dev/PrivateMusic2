import MediaPlayer
import UIKit

@MainActor
final class NowPlayingController {
    private let center = MPNowPlayingInfoCenter.default()
    private var artworkTask: Task<Void, Never>?

    func update(
        track: Track,
        elapsedTime: TimeInterval,
        rate: Float
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
            MPNowPlayingInfoPropertyServiceIdentifier: "Private Music"
        ]

        center.nowPlayingInfo = info

        artworkTask?.cancel()
        guard let artworkURL = track.artworkURL else {
            return
        }
        artworkTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(
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
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        center.nowPlayingInfo = nil
    }
}
