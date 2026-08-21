import Foundation

/// Fine-grained playback clock isolated from `AudioPlayer`'s EnvironmentObject
/// fan-out. Catalog / library rows observe the player for track identity and
/// play state only; scrubbers, mini player, and lyrics observe this model.
@MainActor
@Observable
final class PlaybackProgressModel {
    private(set) var elapsedTime: TimeInterval = 0

    /// Minimum delta before SwiftUI is notified. Keeps ~4 Hz UI updates while
    /// the AVPlayer observer can sample faster for listening metrics.
    static let publishThreshold: TimeInterval = 0.25

    func update(
        _ value: TimeInterval,
        force: Bool = false
    ) {
        let sanitized = max(value, 0)
        guard force || abs(elapsedTime - sanitized) >= Self.publishThreshold
        else {
            return
        }
        elapsedTime = sanitized
    }

    func reset(to value: TimeInterval = 0) {
        elapsedTime = max(value, 0)
    }
}

/// Track identity, queue source + play state for dense list rows, isolated from
/// `AudioPlayer`'s EnvironmentObject fan-out the same way the model above
/// isolates the clock: buffering / duration / shuffle changes on the player
/// must not invalidate every visible row.
@MainActor
@Observable
final class PlaybackHighlightModel {
    private(set) var currentTrackID: String?
    private(set) var isPlaying = false
    /// What started the current queue, so shelves (library/catalog cards)
    /// can flip their play chip to a pause chip without observing the full
    /// `AudioPlayer` and rebuilding on every buffering / duration tick.
    private(set) var queueSource: QueueSource?
    /// Artist credit of the current track. Home's What's Next occupancy
    /// needs it without observing `AudioPlayer` on every progress tick.
    private(set) var currentArtist: String?
    /// Display metadata mirrored for Home's hero without observing
    /// `AudioPlayer` on transport ticks.
    private(set) var currentTrackTitle: String?
    private(set) var currentTrackArtworkURL: URL?
    private(set) var queueContextTitle: String?

    /// No-op when nothing changed: the player mirrors its state here on every
    /// queue / index / transport mutation, and most of those repeat the same
    /// values.
    func update(
        currentTrackID: String?,
        isPlaying: Bool,
        queueSource: QueueSource? = nil,
        currentArtist: String? = nil,
        currentTrackTitle: String? = nil,
        currentTrackArtworkURL: URL? = nil,
        queueContextTitle: String? = nil
    ) {
        if self.currentTrackID != currentTrackID {
            self.currentTrackID = currentTrackID
        }
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }
        if self.queueSource != queueSource {
            self.queueSource = queueSource
        }
        if self.currentArtist != currentArtist {
            self.currentArtist = currentArtist
        }
        if self.currentTrackTitle != currentTrackTitle {
            self.currentTrackTitle = currentTrackTitle
        }
        if self.currentTrackArtworkURL != currentTrackArtworkURL {
            self.currentTrackArtworkURL = currentTrackArtworkURL
        }
        if self.queueContextTitle != queueContextTitle {
            self.queueContextTitle = queueContextTitle
        }
    }

    func isCurrent(_ trackID: String) -> Bool {
        currentTrackID == trackID
    }

    /// Whether `source` is the collection currently loaded into the queue
    /// (regardless of transport state) — used to decide play-vs-resume.
    func isCurrentSource(_ source: QueueSource) -> Bool {
        queueSource == source
    }

    /// Whether `source` is the collection currently loaded into the queue
    /// AND actively playing — used to decide play-vs-pause.
    func isPlayingSource(_ source: QueueSource) -> Bool {
        isPlaying && isCurrentSource(source)
    }
}

/// Merges bursty lock-screen / headphone remote commands so pause+toggle
/// does not immediately undo itself.
enum RemoteCommandCoalescing {
    enum Command: Equatable, Sendable {
        case play
        case pause
        case toggle
        case next
        case previous
        case seek(TimeInterval)
    }

    static func merge(
        pending: Command?,
        incoming: Command
    ) -> Command {
        switch (pending, incoming) {
        case (.play, .toggle), (.toggle, .play):
            return .play
        case (.pause, .toggle), (.toggle, .pause):
            return .pause
        case (.play, .pause), (.pause, .play):
            return incoming
        case (.next, .previous), (.previous, .next):
            return incoming
        case let (_, .seek(time)):
            return .seek(time)
        case (.seek, .play), (.seek, .pause), (.seek, .toggle):
            return incoming
        default:
            return incoming
        }
    }
}
