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
    let isBuffering: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let snapshotDate: Date

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
        snapshotDate: .distantPast
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
        snapshotDate: Date = Date()
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
