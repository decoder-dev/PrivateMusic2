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

        let title = album.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !title.isEmpty else { return nil }
        let artistHints = Set(
            album.artists.map {
                $0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ).lowercased()
            }
        )

        let titled = candidates.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == title
        }
        if !artistHints.isEmpty {
            let artistMatched = titled.first {
                hasUsableAccessKey($0)
                    && !$0.artists.isEmpty
                    && $0.artists.contains { artist in
                        let value = artist.folding(
                            options: [.caseInsensitive, .diacriticInsensitive],
                            locale: Locale(identifier: "en_US_POSIX")
                        ).lowercased()
                        return artistHints.contains {
                            value.contains($0) || $0.contains(value)
                        }
                    }
            }
            if let artistMatched { return artistMatched }
        }
        return titled.first(where: hasUsableAccessKey)
            ?? titled.first
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
