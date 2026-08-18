import Foundation

/// Splits the playback queue into "now playing" and everything after it.
enum QueuePresentationPolicy {
    static func upcomingOffsets(
        queueCount: Int,
        currentIndex: Int?
    ) -> [Int] {
        guard queueCount > 0 else { return [] }
        guard let currentIndex,
              currentIndex >= 0,
              currentIndex < queueCount else {
            return Array(0..<queueCount)
        }
        guard currentIndex + 1 < queueCount else { return [] }
        return Array((currentIndex + 1)..<queueCount)
    }
}
