import Foundation

enum WatchRemoteCommand: String, Codable, Sendable {
    case togglePlayPause
    case next
    case previous
}

struct WatchRemoteState: Codable, Equatable, Sendable {
    let trackID: String?
    let title: String
    let artist: String
    let artworkURL: URL?
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval

    static let empty = WatchRemoteState(
        trackID: nil,
        title: "",
        artist: "",
        artworkURL: nil,
        isPlaying: false,
        elapsed: 0,
        duration: 0
    )

    var context: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [WatchRemoteMessageKey.state: data]
    }

    init?(context: [String: Any]) {
        guard let data = context[WatchRemoteMessageKey.state] as? Data,
              let value = try? JSONDecoder().decode(
                WatchRemoteState.self,
                from: data
              ) else {
            return nil
        }
        self = value
    }

    init(
        trackID: String?,
        title: String,
        artist: String,
        artworkURL: URL?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
    }
}

enum WatchRemoteMessageKey {
    static let state = "playerState"
    static let command = "playerCommand"
}
