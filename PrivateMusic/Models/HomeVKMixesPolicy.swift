import Foundation

/// Which VK Mixes compete for Home's single What's Next slot (and still
/// feed Explore). VK's own feed is already relevance-ordered server-side
/// — this is dedup and a cap, not a second ranking model.
enum HomeVKMixesPolicy {
    static let limit = 6

    static func candidates(from mixes: [MusicMix]) -> [MusicMix] {
        var seenIDs = Set<String>()
        var result: [MusicMix] = []
        for mix in mixes {
            let hasTitle = !mix.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard hasTitle, seenIDs.insert(mix.id).inserted else { continue }
            result.append(mix)
            if result.count == limit { break }
        }
        return result
    }
}
