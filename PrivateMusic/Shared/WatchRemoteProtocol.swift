import Foundation

enum WatchRemoteCommand: String, Codable, Sendable {
    case togglePlayPause
    case next
    case previous
    case likeCurrent
}

struct WatchRemoteState: Codable, Equatable, Sendable {
    let trackID: String?
    let title: String
    let artist: String
    let artworkURL: URL?
    let isPlaying: Bool
    let isBuffering: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let snapshotDate: Date
    let isLiked: Bool
    let isMixQueue: Bool

    /// `snapshotDate` is only used for Watch-side elapsed interpolation; it
    /// must not defeat push deduplication or every half-second player tick
    /// would spam `WCSession.updateApplicationContext`.
    static func == (lhs: WatchRemoteState, rhs: WatchRemoteState) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.artworkURL == rhs.artworkURL
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isBuffering == rhs.isBuffering
            && lhs.elapsed == rhs.elapsed
            && lhs.duration == rhs.duration
            && lhs.isLiked == rhs.isLiked
            && lhs.isMixQueue == rhs.isMixQueue
    }

    static let empty = WatchRemoteState(
        trackID: nil,
        title: "",
        artist: "",
        artworkURL: nil,
        isPlaying: false,
        isBuffering: false,
        elapsed: 0,
        duration: 0,
        snapshotDate: .distantPast,
        isLiked: false,
        isMixQueue: false
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
        isBuffering: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        snapshotDate: Date = Date(),
        isLiked: Bool = false,
        isMixQueue: Bool = false
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.elapsed = elapsed
        self.duration = duration
        self.snapshotDate = snapshotDate
        self.isLiked = isLiked
        self.isMixQueue = isMixQueue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decodeIfPresent(String.self, forKey: .trackID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        isBuffering = try container.decodeIfPresent(Bool.self, forKey: .isBuffering) ?? false
        elapsed = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        snapshotDate = try container.decodeIfPresent(Date.self, forKey: .snapshotDate)
            ?? .distantPast
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isMixQueue = try container.decodeIfPresent(Bool.self, forKey: .isMixQueue) ?? false
    }

    func displayedElapsed(at date: Date) -> TimeInterval {
        guard isPlaying, !isBuffering, snapshotDate != .distantPast else {
            return min(max(elapsed, 0), max(duration, 0))
        }
        let advanced = elapsed + max(0, date.timeIntervalSince(snapshotDate))
        return min(max(advanced, 0), max(duration, 0))
    }
}

struct WatchRemoteCommandEnvelope: Codable, Equatable, Sendable {
    let command: WatchRemoteCommand
    let issuedAt: Date
    let trackID: String?

    init(
        command: WatchRemoteCommand,
        issuedAt: Date = Date(),
        trackID: String?
    ) {
        self.command = command
        self.issuedAt = issuedAt
        self.trackID = trackID
    }

    var message: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [WatchRemoteMessageKey.commandEnvelope: data]
    }

    init?(message: [String: Any]) {
        guard let data = message[
            WatchRemoteMessageKey.commandEnvelope
        ] as? Data,
        let value = try? JSONDecoder().decode(
            WatchRemoteCommandEnvelope.self,
            from: data
        ) else {
            return nil
        }
        self = value
    }

    func isValid(
        at date: Date,
        currentTrackID: String?,
        maximumAge: TimeInterval = 15
    ) -> Bool {
        let age = date.timeIntervalSince(issuedAt)
        return (-5.0...maximumAge).contains(age)
            && trackID == currentTrackID
    }
}

enum WatchRemoteMessageKey {
    static let state = "playerState"
    static let commandEnvelope = "playerCommandEnvelope"
    static let accepted = "commandAccepted"
}
