import Foundation

enum QueueSourcePlaybackAction: Equatable, Sendable {
    case start
    case resume
    case pause

    var systemImage: String {
        switch self {
        case .start, .resume:
            return "play.fill"
        case .pause:
            return "pause.fill"
        }
    }

    var labelKey: String {
        switch self {
        case .start, .resume:
            return "Воспроизвести"
        case .pause:
            return "Приостановить"
        }
    }

    func accessibilityLabelKey(playKey: String) -> String {
        switch self {
        case .start, .resume:
            return playKey
        case .pause:
            return labelKey
        }
    }

    static func resolve(
        target: QueueSource,
        isPlaying: Bool,
        queueSource: QueueSource?
    ) -> QueueSourcePlaybackAction {
        guard queueSource == target else { return .start }
        return isPlaying ? .pause : .resume
    }
}
