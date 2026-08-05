import Foundation

struct VKArtist: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let photoURL: URL?
    let isAlbumCover: Bool

    init(
        id: String,
        name: String,
        photoURL: URL? = nil,
        isAlbumCover: Bool = false
    ) {
        self.id = id
        self.name = name
        self.photoURL = photoURL
        self.isAlbumCover = isAlbumCover
    }
}

struct CatalogSectionRef: Hashable, Sendable {
    let id: String
    let title: String
    let url: String?

    var searchableBlob: String {
        "\(title) \(url ?? "")".lowercased()
    }
}

struct VKCatalogSnapshot: Sendable {
    var mixes: [MusicMix]
    var newReleases: [Album]
    var sections: [CatalogSectionRef]
}

enum AlbumFollowPolicy {
    /// VK has no `audio.unfollowPlaylist`. Removing a followed album/playlist
    /// from the library uses the same `audio.deletePlaylist` method as deleting
    /// a user's own playlist.
    static func methodPath(follow: Bool) -> String {
        follow
            ? "/method/audio.followPlaylist"
            : "/method/audio.deletePlaylist"
    }
}

enum MixTrackRequestPolicy {
    /// Stream mixes often return ~3 items even when a larger count is asked.
    static let pageSize = 100
    /// Concurrent pages to fill a usable queue without 10× API spam.
    static let pageCount = 4
    /// Cap kept for the player queue (was 30 after fetching 10 pages).
    static let queueLimit = 80
}

enum CatalogSectionPolicy {
    static func looksLikeMixSection(_ section: CatalogSectionRef) -> Bool {
        let blob = section.searchableBlob
        let markers = [
            "mix", "микс", "stream", "подбор", "radio", "вкус",
            "для вас", "for you", "discover", "поток"
        ]
        return markers.contains { blob.contains($0) }
    }

    static func looksLikeReleasesSection(_ section: CatalogSectionRef) -> Bool {
        let blob = section.searchableBlob
        let markers = [
            "release", "релиз", "нов", "выход", "премьер", "album",
            "альбом", "new music", "свеж"
        ]
        return markers.contains { blob.contains($0) }
    }
}

enum VKArtistMatch {
    static func best(
        in candidates: [VKArtist],
        named query: String
    ) -> VKArtist? {
        let ranked = candidates.compactMap { candidate -> (VKArtist, Int)? in
            let score = score(query: query, candidate: candidate.name)
            guard score > 0 else { return nil }
            return (candidate, score)
        }
        return ranked.max(by: { $0.1 < $1.1 })?.0
    }

    static func score(query: String, candidate: String) -> Int {
        let target = normalized(query)
        let value = normalized(candidate)
        guard !target.isEmpty, !value.isEmpty else { return 0 }
        if value == target { return 100 }
        if collaborationParts(in: value).contains(target) { return 80 }
        if value.hasPrefix(target) || target.hasPrefix(value) {
            let shorter = min(value.count, target.count)
            let longer = max(value.count, target.count)
            guard shorter >= 3, Double(shorter) / Double(longer) >= 0.72 else {
                return 0
            }
            return 55
        }
        return 0
    }

    private static func collaborationParts(in value: String) -> [String] {
        let separators = [
            ",", ";", " feat. ", " feat ", " featuring ", " ft. ", " ft "
        ]
        return separators.reduce([value]) { parts, separator in
            parts.flatMap { $0.components(separatedBy: separator) }
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map(normalized)
        .filter { !$0.isEmpty }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
