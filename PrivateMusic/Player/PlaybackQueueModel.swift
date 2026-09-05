import AVFoundation
import MediaPlayer

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

enum SleepTimerMode: Equatable, Sendable {
    case afterMinutes(Int)
    case endOfTrack
    case endOfQueue

    var statusLabel: String {
        switch self {
        case let .afterMinutes(minutes):
            return L10n.minutes(minutes)
        case .endOfTrack:
            return L10n.text("sleep.end_of_track")
        case .endOfQueue:
            return L10n.text("sleep.end_of_queue")
        }
    }
}

/// What started the current queue, for display in the full-screen player.
/// Callers that start playback from a named collection or from Медиатека
/// pass the matching case; anything else (search results, recommendations,
/// artist tracks, offline files, an "open player" context-menu action, …)
/// is left `nil` and treated as an implicit automix seeded by the tapped
/// track — see `AudioPlayer.queueContextTitle`.
enum QueueSource: Equatable {
    /// A mix session. `id` is the stable identity (catalog mix id, or a
    /// synthetic id for artist radio / my-music / seed mixes); `title` is
    /// display-only. Comparing queues by title alone used to rerank the
    /// wrong mix when VK shipped duplicate shelf names.
    case mix(id: String, title: String)
    case playlist(title: String)
    case album(title: String)
    case history
    /// The Медиатека track list. It has no title of its own, and without a
    /// case for it the player captioned a library queue as a mix seeded by
    /// the tapped track — which is not what is playing.
    case library

    static func catalogMix(_ mix: MusicMix) -> QueueSource {
        .mix(id: mix.id, title: mix.title)
    }

    static func myMusicMix(title: String) -> QueueSource {
        .mix(id: MixQueueIdentity.myMusic, title: title)
    }

    static func artistMix(named name: String, title: String) -> QueueSource {
        .mix(id: MixQueueIdentity.artist(name), title: title)
    }

    static func seedMix(trackID: String, title: String) -> QueueSource {
        .mix(id: MixQueueIdentity.seed(trackID), title: title)
    }

    var mixID: String? {
        if case let .mix(id, _) = self { return id }
        return nil
    }

    var mixTitle: String? {
        if case let .mix(_, title) = self { return title }
        return nil
    }

    /// Personal station and "mix from my music" share Selena wave filters /
    /// bandit ranking — catalog VK mixes do not.
    var usesSelenaWaveFilters: Bool {
        guard let mixID else { return false }
        return mixID == MusicMix.common.id || mixID == MixQueueIdentity.myMusic
    }
}

/// Stable ids for mix queues that are not catalog shelves.
enum MixQueueIdentity {
    static let myMusic = "my-music"

    static func artist(_ name: String) -> String {
        "artist:" + MixFeedbackPolicy.normalized(name)
    }

    static func seed(_ trackID: String) -> String {
        "seed:" + trackID
    }
}

enum PendingPlayerSheet: Equatable, Sendable {
    case queue
}

enum QueueSourceTitle {
    static func isUsable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

