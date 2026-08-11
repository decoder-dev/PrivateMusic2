import Foundation

/// Queue capacity for playback started from Медиатека.
///
/// `MixTrackRequestPolicy.queueLimit` sizes an endless mix: radio refills
/// forever, so holding more than a short upcoming window is wasted work.
/// Медиатека is the opposite kind of queue — a finite list the user owns and
/// expects to play through. Sharing the mix cap with it stranded a
/// 833-track library at «Трек 1 из 100», because every library page handed
/// to `appendToQueue` after the first 80 upcoming tracks was dropped.
///
/// The library ceiling is deliberately soft: high enough that a real library
/// plays through as one queue, low enough that a continuation that keeps
/// handing back pages cannot grow the queue (and the persisted snapshot)
/// without bound.
enum LibraryQueuePolicy {
    /// Upcoming tracks a queue started from Медиатека may hold.
    static let queueLimit = 2_000

    static func isLibraryQueue(_ source: QueueSource?) -> Bool {
        source == .library
    }

    /// Upcoming-window budget for the queue `source` describes. Mix, Selena
    /// and every implicit automix keep the mix limit.
    static func upcomingLimit(for source: QueueSource?) -> Int {
        isLibraryQueue(source)
            ? queueLimit
            : MixTrackRequestPolicy.queueLimit
    }

    /// How many appended tracks still fit behind an upcoming window of
    /// `upcomingCount`.
    static func appendableCount(
        upcomingCount: Int,
        source: QueueSource?
    ) -> Int {
        max(upcomingLimit(for: source) - max(upcomingCount, 0), 0)
    }
}
