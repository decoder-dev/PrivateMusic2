import Foundation

enum WatchRemoteCommand: String, Codable, Sendable {
    case togglePlayPause
    case next
    case previous
    case likeCurrent
    case unlikeCurrent
    case playQueueItem
}

struct WatchQueueItem: Codable, Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
}

/// Caps the Watch application-context payload. A library queue can hold
/// thousands of tracks; WCSession context cannot.
enum WatchQueueSnapshotPolicy {
    static let maxCount = 20

    /// Contiguous window around `currentIndex`, at most `maxCount` items.
    /// Near either end the window slides so it stays inside `items` and
    /// still contains the current track.
    static func window<Item>(
        items: [Item],
        currentIndex: Int?,
        maxCount: Int = maxCount
    ) -> (items: [Item], currentIndex: Int?) {
        guard !items.isEmpty else { return ([], nil) }
        let count = min(max(maxCount, 0), items.count)
        guard count > 0 else { return ([], nil) }

        guard let current = currentIndex, items.indices.contains(current) else {
            return (Array(items.prefix(count)), nil)
        }

        let leading = count / 2
        var start = max(0, current - leading)
        var end = start + count
        if end > items.count {
            end = items.count
            start = max(0, end - count)
        }
        return (Array(items[start..<end]), current - start)
    }
}

/// Age + track-binding rules for Watch → iPhone command envelopes.
enum WatchRemoteCommandValidationPolicy {
    static let maximumAge: TimeInterval = 15
    static let issuedAtSkew: TimeInterval = 5

    static func isValid(
        command: WatchRemoteCommand,
        issuedAt: Date,
        trackID: String?,
        at date: Date,
        currentTrackID: String?,
        queuedTrackIDs: [String],
        maximumAge: TimeInterval = maximumAge
    ) -> Bool {
        let age = date.timeIntervalSince(issuedAt)
        guard ((-issuedAtSkew)...maximumAge).contains(age) else {
            return false
        }
        switch command {
        case .playQueueItem:
            guard let trackID else { return false }
            return queuedTrackIDs.contains(trackID)
                && trackID != currentTrackID
        case .togglePlayPause, .next, .previous, .likeCurrent, .unlikeCurrent:
            return trackID == currentTrackID
        }
    }
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
    let queue: [WatchQueueItem]
    let currentQueueIndex: Int?

    /// `snapshotDate` is only used for Watch-side elapsed interpolation; it
    /// must not defeat push deduplication or every half-second player tick
    /// would spam `WCSession.updateApplicationContext`. Elapsed is bucketed
    /// the same way — the Watch extrapolates between coarse drift corrections.
    static func == (lhs: WatchRemoteState, rhs: WatchRemoteState) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.artworkURL == rhs.artworkURL
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isBuffering == rhs.isBuffering
            && Self.elapsedBucket(lhs.elapsed) == Self.elapsedBucket(rhs.elapsed)
            && lhs.duration == rhs.duration
            && lhs.isLiked == rhs.isLiked
            && lhs.isMixQueue == rhs.isMixQueue
            && lhs.queue == rhs.queue
            && lhs.currentQueueIndex == rhs.currentQueueIndex
    }

    /// Matches phone-side Watch drift correction cadence.
    static let elapsedBucketSeconds: TimeInterval = 20

    static func elapsedBucket(_ elapsed: TimeInterval) -> Int {
        let width = max(Int(elapsedBucketSeconds), 1)
        return Int(max(elapsed, 0).rounded(.down)) / width
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
        isMixQueue: false,
        queue: [],
        currentQueueIndex: nil
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
        isMixQueue: Bool = false,
        queue: [WatchQueueItem] = [],
        currentQueueIndex: Int? = nil
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
        self.queue = queue
        self.currentQueueIndex = currentQueueIndex
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
        queue = try container.decodeIfPresent(
            [WatchQueueItem].self,
            forKey: .queue
        ) ?? []
        currentQueueIndex = try container.decodeIfPresent(
            Int.self,
            forKey: .currentQueueIndex
        )
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
        maximumAge: TimeInterval = WatchRemoteCommandValidationPolicy.maximumAge
    ) -> Bool {
        isValid(
            at: date,
            currentTrackID: currentTrackID,
            queuedTrackIDs: [],
            maximumAge: maximumAge
        )
    }

    func isValid(
        at date: Date,
        currentTrackID: String?,
        queuedTrackIDs: [String],
        maximumAge: TimeInterval = WatchRemoteCommandValidationPolicy.maximumAge
    ) -> Bool {
        WatchRemoteCommandValidationPolicy.isValid(
            command: command,
            issuedAt: issuedAt,
            trackID: trackID,
            at: date,
            currentTrackID: currentTrackID,
            queuedTrackIDs: queuedTrackIDs,
            maximumAge: maximumAge
        )
    }
}

enum WatchRemoteMessageKey {
    static let state = "playerState"
    static let commandEnvelope = "playerCommandEnvelope"
    static let accepted = "commandAccepted"
}
