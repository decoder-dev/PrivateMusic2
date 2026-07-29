import Foundation

enum PlaybackQueueBuilder {
    static func normalized(
        selected track: Track,
        tracks: [Track]
    ) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for item in tracks {
            let resolved = item.id == track.id ? track : item
            if seen.insert(resolved.id).inserted {
                result.append(resolved)
            }
        }
        if seen.insert(track.id).inserted {
            result.insert(track, at: 0)
        }
        return result
    }
}
