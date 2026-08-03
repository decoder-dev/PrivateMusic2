import Foundation

enum ListeningProgressPolicy {
    static let requiredFraction = 0.30

    static func shouldMarkListened(
        accumulatedPlayback: TimeInterval,
        duration: TimeInterval,
        alreadyMarked: Bool
    ) -> Bool {
        guard !alreadyMarked,
              accumulatedPlayback.isFinite,
              duration.isFinite,
              duration > 0 else {
            return false
        }
        return accumulatedPlayback / duration >= requiredFraction
    }
}
