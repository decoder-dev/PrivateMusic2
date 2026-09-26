import Foundation

enum PlaybackQueueEditing {
    /// Offsets are relative to the upcoming section, never the playing head.
    static func movingUpcoming<Item>(
        in queue: [Item],
        currentIndex: Int?,
        from offsets: IndexSet,
        to destination: Int
    ) -> [Item] {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return queue }
        let headCount = currentIndex + 1
        let upcoming = Array(queue.dropFirst(headCount))
        guard !offsets.isEmpty,
              offsets.allSatisfy({ upcoming.indices.contains($0) }),
              (0...upcoming.count).contains(destination) else { return queue }
        let moved = offsets.map { upcoming[$0] }
        var remaining = upcoming.enumerated().compactMap {
            offsets.contains($0.offset) ? nil : $0.element
        }
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: insertion)
        return Array(queue.prefix(headCount)) + remaining
    }
}
