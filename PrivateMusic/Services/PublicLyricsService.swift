import Foundation

/// Public lyric sources remain available when the VK session has expired.
struct PublicLyricsService: Sendable {
    func lyrics(for track: Track) async throws -> Lyrics {
        do {
            return try await LRCLyricsService().lyrics(for: track)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }
        return try await GeniusLyricsService().lyrics(for: track)
    }
}
