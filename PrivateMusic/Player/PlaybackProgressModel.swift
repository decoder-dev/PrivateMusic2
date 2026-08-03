import Combine
import Foundation

/// Fine-grained playback clock isolated from `AudioPlayer`'s EnvironmentObject
/// fan-out. Catalog / library rows observe the player for track identity and
/// play state only; scrubbers, mini player, and lyrics observe this model.
@MainActor
final class PlaybackProgressModel: ObservableObject {
    @Published private(set) var elapsedTime: TimeInterval = 0

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
