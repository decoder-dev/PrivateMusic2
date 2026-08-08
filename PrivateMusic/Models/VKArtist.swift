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

enum AlbumAccessPolicy {
    /// Community / official album owners are negative; VK requires
    /// `access_key` for `audio.get` / `execute.getPlaylist` on those.
    static func requiresAccessKey(_ album: Album) -> Bool {
        album.ownerID < 0
    }

    static func usableAccessKey(from album: Album) -> String? {
        guard let key = album.accessKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !key.isEmpty else {
            return nil
        }
        return key
    }

    static func hasUsableAccessKey(_ album: Album) -> Bool {
        usableAccessKey(from: album) != nil
    }

    static func needsAccessKeyResolution(_ album: Album) -> Bool {
        requiresAccessKey(album) && !hasUsableAccessKey(album)
    }

    static func isAudioAccessDenied(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case let .server(code, message) = apiError else {
            return false
        }
        if [15, 201, 203, 204].contains(code) {
            return true
        }
        let lower = message.lowercased()
        return lower.contains("access denied")
            || lower.contains("access to users audio")
            || lower.contains("permission to perform this action")
    }

    static func preferredMatch(
        in candidates: [Album],
        for album: Album
    ) -> Album? {
        if let exact = candidates.first(where: {
            $0.compositeID == album.compositeID && hasUsableAccessKey($0)
        }) {
            return exact
        }
        if let exact = candidates.first(where: {
            $0.compositeID == album.compositeID
        }) {
            return exact
        }

        let title = normalized(album.title)
        guard !title.isEmpty else {
            return candidates.first(where: hasUsableAccessKey)
        }
        let artistHints = Set(album.artists.map(normalized).filter { !$0.isEmpty })

        let titled = candidates.filter {
            titlesMatch(normalized($0.title), title)
        }
        if !artistHints.isEmpty {
            let artistMatched = titled.filter { candidate in
                !candidate.artists.isEmpty
                    && candidate.artists.contains { artist in
                        let value = normalized(artist)
                        return artistHints.contains {
                            value.contains($0) || $0.contains(value)
                        }
                    }
            }
            if let withKey = artistMatched.first(where: hasUsableAccessKey) {
                return withKey
            }
            if let first = artistMatched.first {
                return first
            }
        }
        return titled.first(where: hasUsableAccessKey)
            ?? titled.first
            ?? candidates.first(where: hasUsableAccessKey)
    }

    static func searchQueries(for album: Album) -> [String] {
        var queries: [String] = []
        let title = album.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let artist = album.artists.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Album.isUsableTitle(title), !artist.isEmpty {
            queries.append("\(title) \(artist)")
            queries.append("\(artist) \(title)")
        }
        if Album.isUsableTitle(title) {
            queries.append(title)
        }
        if !artist.isEmpty {
            queries.append(artist)
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    static func trackBelongs(_ track: Track, to album: Album) -> Bool {
        if let reference = track.albumReference,
           reference.albumID == album.albumID,
           reference.ownerID == album.ownerID {
            return true
        }
        let albumTitle = normalized(album.title)
        guard !albumTitle.isEmpty,
              let trackAlbum = track.albumTitle.map(normalized),
              !trackAlbum.isEmpty,
              titlesMatch(trackAlbum, albumTitle) else {
            return false
        }
        return artistMatches(track, album: album)
            || album.artists.isEmpty
    }

    static func artistMatches(_ track: Track, album: Album) -> Bool {
        let artistHints = Set(
            album.artists.map(normalized).filter { !$0.isEmpty }
        )
        guard !artistHints.isEmpty else { return true }
        let trackArtist = normalized(track.artist)
        return artistHints.contains {
            trackArtist.contains($0) || $0.contains(trackArtist)
        }
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
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

enum MixTrackRequestPolicy {
    /// Stream mixes often return ~3 items even when a larger count is asked.
    static let pageSize = 100
    /// Concurrent pages to fill a usable queue without 10× API spam.
    static let pageCount = 4
    /// First page only — start playback before the rest arrive.
    static let bootstrapPages = 1
    /// Cap kept for the player queue (was 30 after fetching 10 pages).
    static let queueLimit = 80
    /// Prefetch the next mix batch when this many tracks remain after current.
    static let continuationRemainingThreshold = 6
}

enum ContinuationPrefetchPolicy {
    static func shouldPrefetch(currentIndex: Int?, queueCount: Int) -> Bool {
        guard let currentIndex, queueCount > 0 else { return false }
        let remaining = queueCount - currentIndex - 1
        return remaining <= MixTrackRequestPolicy.continuationRemainingThreshold
    }
}

enum CatalogSectionPolicy {
    /// Max official mix/release sections to hydrate in parallel.
    static let hydrationLimit = 8

    static func looksLikeMixSection(_ section: CatalogSectionRef) -> Bool {
        let blob = section.searchableBlob
        let markers = [
            "mix", "микс", "stream", "подбор", "radio", "вкус",
            "для вас", "for you", "discover", "поток", "mood",
            "настроен", "активност", "activity", "жанр", "genre",
            "section=mix", "listen together", "друг", "вайб", "vibe",
            "спокойн", "грустн", "радост", "энерг", "chart", "чарт",
            "открыт", "новинк", "плейлист дня", "хит", "kids", "дет"
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

    static func looksLikeKidsSection(_ section: CatalogSectionRef) -> Bool {
        let blob = section.searchableBlob
        let markers = [
            "дет", "kids", "child", "сказк", "колыбел", "семья", "family"
        ]
        return markers.contains { blob.contains($0) }
    }

    static func looksLikeChartSection(_ section: CatalogSectionRef) -> Bool {
        let blob = section.searchableBlob
        let markers = [
            "chart", "чарт", "топ", "top", "хит", "hit", "популяр"
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
