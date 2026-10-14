import Foundation

struct QueueRemovalUndo {
    let id: UUID
    let queue: [Track]
    let sourceOrder: [Track]
    let index: Int
    let elapsed: TimeInterval
    let wasPlaying: Bool
    let source: QueueSource?
    let shuffled: Bool
    let continuationSuppressed: Bool
    let pinnedNextIDs: Set<String>
    let restoredIDs: Set<String>
    let expectedQueueIDs: [String]
    let expectedCurrentID: String?
}
