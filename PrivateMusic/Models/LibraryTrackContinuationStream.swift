import Foundation

enum LibraryTrackContinuationPolicy {
    /// Same window `audio.get` is paged with on the library screen, so the
    /// continuation lines up with the offsets the list already walked.
    static let pageSize = 100
}

/// Keeps a queue started from Медиатека playing in library order past the
/// tracks the screen has loaded.
///
/// The library used to continue into personal recommendations as soon as the
/// loaded window ran out, so a queue that started «по порядку» turned into
/// unrelated tracks a few songs later. This cursor hands over the next
/// `audio.get` page in VK's own order first, and only falls back to
/// recommendations once the library itself is exhausted — so playback still
/// never stops.
actor LibraryTrackContinuationCursor {
    private var nextOffset: Int?
    private var knownIDs: Set<String>
    private let pageSize: Int

    init(
        startingOffset: Int,
        knownTracks: [Track] = [],
        pageSize: Int = LibraryTrackContinuationPolicy.pageSize
    ) {
        self.nextOffset = max(startingOffset, 0)
        self.knownIDs = Set(knownTracks.map(\.id))
        self.pageSize = max(pageSize, 1)
    }

    func next(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        let additions = try await nextLibraryPage(
            accessToken: accessToken,
            musicService: musicService
        )
        if !additions.isEmpty { return additions }
        // An all-duplicate page still advanced the cursor; only give up on
        // the library once VK says there is nothing after it.
        if nextOffset != nil { return [] }
        return try await musicService.recommendations(
            accessToken: accessToken
        ).filter { knownIDs.insert($0.id).inserted }
    }

    func nextLibraryPage(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        if let offset = nextOffset {
            let page = try await musicService.library(
                accessToken: accessToken,
                offset: offset,
                count: pageSize
            )
            let additions = page.items.filter {
                knownIDs.insert($0.id).inserted
            }
            nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            if !additions.isEmpty { return additions }
        }
        return []
    }
}
