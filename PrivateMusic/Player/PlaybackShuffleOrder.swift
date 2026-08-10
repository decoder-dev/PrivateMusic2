import Foundation

/// Keeps «Перемешать» reversible.
///
/// Shuffling used to overwrite the queue in place, so the source order was
/// gone the moment it was applied: turning shuffle back off simply froze the
/// shuffled order, and the library never played «по очереди» again. The
/// player now remembers the order a queue arrived in and rebuilds it here.
enum PlaybackShuffleOrder {
    /// The playing track first, everything else in random order.
    static func shuffled(_ tracks: [Track], keeping current: Track) -> [Track] {
        [current] + tracks.filter { $0.id != current.id }.shuffled()
    }

    /// Rebuilds `sourceOrder` from whatever the queue still holds.
    ///
    /// Tracks the queue picked up while shuffle was on — «Играть следующим»,
    /// mix continuation refills — are unknown to the snapshot, so they keep
    /// their relative order and follow the restored block.
    static func restored(
        queue: [Track],
        sourceOrder: [Track]
    ) -> [Track] {
        guard !sourceOrder.isEmpty else { return queue }
        let live = Set(queue.map(\.id))
        var restored: [Track] = []
        var placed = Set<String>()
        for track in sourceOrder where live.contains(track.id) {
            guard placed.insert(track.id).inserted else { continue }
            restored.append(track)
        }
        for track in queue where !placed.contains(track.id) {
            placed.insert(track.id)
            restored.append(track)
        }
        return restored
    }
}
