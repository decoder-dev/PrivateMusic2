import Foundation

/// Human-readable label for what started the current queue. Shared by the
/// player chrome and `PlaybackHighlightModel` so Home does not observe
/// `AudioPlayer` just to paint the context chip.
enum QueueContextTitlePolicy {
    static func resolve(
        queueSource: QueueSource?,
        queueSeedTrackTitle: String?
    ) -> String {
        switch queueSource {
        case let .mix(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .playlist(title) where QueueSourceTitle.isUsable(title):
            return title
        case let .album(title) where QueueSourceTitle.isUsable(title):
            return title
        case .history:
            return L10n.text("listening_history")
        case .library:
            return L10n.text("library.your_tracks")
        default:
            if let seed = queueSeedTrackTitle,
               QueueSourceTitle.isUsable(seed) {
                return L10n.format("mix_based_on_0", seed)
            }
            return L10n.text("player.your_queue")
        }
    }
}
