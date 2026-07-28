import Foundation

struct MusicPage<Item: Sendable>: Sendable {
    let items: [Item]
    let totalCount: Int
    let nextOffset: Int?
}
