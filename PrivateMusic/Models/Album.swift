import Foundation

struct AlbumReference: Codable, Hashable, Sendable {
    let albumID: Int
    let ownerID: Int
    let accessKey: String?

    func album(
        title: String,
        artist: String,
        artworkURL: URL?
    ) -> Album {
        Album(
            id: albumID,
            ownerID: ownerID,
            title: title,
            count: 0,
            artworkURL: artworkURL,
            accessKey: accessKey,
            artists: artist.isEmpty ? [] : [artist]
        )
    }
}

struct Album: Decodable, Hashable, Identifiable, Sendable {
    struct Artist: Decodable, Hashable, Sendable {
        let name: String
    }

    private struct ArtworkCandidate {
        let url: URL
        let size: Int
        let order: Int
    }

    let albumID: Int
    let ownerID: Int
    let title: String
    let description: String?
    let count: Int
    let artworkURL: URL?
    let accessKey: String?
    let artists: [String]
    let releaseDate: Date?
    let releaseYear: Int?
    let isFollowed: Bool
    let followHash: String?

    var id: String { compositeID }
    var compositeID: String { "\(ownerID)_\(albumID)" }
    var artistText: String {
        artists.isEmpty ? L10n.text("unknown_artist") : artists.joined(separator: ", ")
    }

    init(
        id: Int,
        ownerID: Int,
        title: String,
        description: String? = nil,
        count: Int,
        artworkURL: URL? = nil,
        accessKey: String? = nil,
        artists: [String] = [],
        releaseDate: Date? = nil,
        releaseYear: Int? = nil,
        isFollowed: Bool = false,
        followHash: String? = nil
    ) {
        self.albumID = id
        self.ownerID = ownerID
        self.title = title
        self.description = description
        self.count = count
        self.artworkURL = artworkURL
        self.accessKey = accessKey
        self.artists = artists
        self.releaseDate = releaseDate
        self.releaseYear = releaseYear
        self.isFollowed = isFollowed
        self.followHash = followHash
    }

    func updatingFollowed(_ followed: Bool) -> Album {
        Album(
            id: albumID,
            ownerID: ownerID,
            title: title,
            description: description,
            count: count,
            artworkURL: artworkURL,
            accessKey: accessKey,
            artists: artists,
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            isFollowed: followed,
            followHash: followHash
        )
    }

    /// Prefer a searchable VK album payload. `access_key` is only valid for
    /// its own `owner_id` + `id` pair, so a different composite id replaces
    /// the locator entirely instead of grafting the key onto a stale id.
    func mergingAccessMetadata(from other: Album) -> Album {
        let useOtherLocator = other.compositeID != compositeID
            && AlbumAccessPolicy.hasUsableAccessKey(other)
        return Album(
            id: useOtherLocator ? other.albumID : albumID,
            ownerID: useOtherLocator ? other.ownerID : ownerID,
            title: Self.isUsableTitle(title) ? title : other.title,
            description: description ?? other.description,
            count: other.count > 0 ? other.count : count,
            artworkURL: artworkURL ?? other.artworkURL,
            accessKey: AlbumAccessPolicy.usableAccessKey(from: other)
                ?? AlbumAccessPolicy.usableAccessKey(from: self),
            artists: artists.isEmpty ? other.artists : artists,
            releaseDate: releaseDate ?? other.releaseDate,
            releaseYear: releaseYear ?? other.releaseYear,
            isFollowed: isFollowed || other.isFollowed,
            followHash: other.followHash ?? followHash
        )
    }

    enum CodingKeys: String, CodingKey {
        case albumID = "id"
        case title, description, count, size, year, artist, artists, photo
        case ownerID = "owner_id"
        case photo600 = "photo_600"
        case photo300 = "photo_300"
        case photo270 = "photo_270"
        case thumb
        case accessKey = "access_key"
        case mainArtists = "main_artists"
        case releaseDate = "release_date"
        case isFollowed = "is_followed"
        case followed
        case followHash = "follow_hash"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albumID = try container.decode(Int.self, forKey: .albumID)
        ownerID = try container.decode(Int.self, forKey: .ownerID)
        title = try container.decodeIfPresent(
            String.self,
            forKey: .title
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
            ?? container.decodeIfPresent(Int.self, forKey: .size)
            ?? 0
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)
        let mainArtists = (try? container.decode(
            [Artist].self,
            forKey: .mainArtists
        ))?.map(\.name) ?? []
        let objectArtists = (try? container.decode(
            [Artist].self,
            forKey: .artists
        ))?.map(\.name) ?? []
        let stringArtists = (try? container.decode(
            [String].self,
            forKey: .artists
        )) ?? []
        let scalarArtist = try container.decodeIfPresent(
            String.self,
            forKey: .artist
        )
        artists = Self.uniqueMetadata(
            mainArtists + objectArtists + stringArtists + [scalarArtist]
                .compactMap { $0 }
        )
        let followedBool = try? container.decode(Bool.self, forKey: .isFollowed)
        let followedInteger =
            (try? container.decode(Int.self, forKey: .isFollowed)) == 1
            || (try? container.decode(Int.self, forKey: .followed)) == 1
        isFollowed = followedBool ?? followedInteger
        followHash = try container.decodeIfPresent(String.self, forKey: .followHash)
        artworkURL = Self.artworkURL(from: try? JSONValue(from: decoder))
        let integerReleaseDate = try? container.decode(
            Int.self,
            forKey: .releaseDate
        )
        let stringReleaseDate = try? container.decode(
            String.self,
            forKey: .releaseDate
        )
        if let timestamp = integerReleaseDate,
           timestamp > 10_000 {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            releaseDate = date
            releaseYear = Calendar(identifier: .gregorian)
                .component(.year, from: date)
        } else if let raw = stringReleaseDate,
                  let timestamp = Int(raw),
                  timestamp > 10_000 {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            releaseDate = date
            releaseYear = Calendar(identifier: .gregorian)
                .component(.year, from: date)
        } else if let year = integerReleaseDate,
                  (1900...2200).contains(year) {
            releaseDate = nil
            releaseYear = year
        } else if let raw = stringReleaseDate,
                  let year = Int(raw),
                  (1900...2200).contains(year) {
            releaseDate = nil
            releaseYear = year
        } else if let raw = stringReleaseDate,
                  let parsed = ISO8601DateFormatter().date(from: raw) {
            releaseDate = parsed
            releaseYear = Calendar(identifier: .gregorian)
                .component(.year, from: parsed)
        } else if let year = try container.decodeIfPresent(Int.self, forKey: .year),
                  (1900...2200).contains(year) {
            releaseDate = nil
            releaseYear = year
        } else {
            releaseDate = nil
            releaseYear = nil
        }
    }

    static func isUsableTitle(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.caseInsensitiveCompare("unnamed") != .orderedSame
    }

    func normalized(using tracks: [Track]) -> Album {
        let fallbackTitle = Self.mostFrequent(
            tracks.compactMap(\.albumTitle).filter(Self.isUsableTitle)
        )
        let fallbackArtist = Self.mostFrequent(
            tracks.map(\.artist).filter(Self.isUsableMetadata)
        )
        return Album(
            id: albumID,
            ownerID: ownerID,
            title: Self.isUsableTitle(title)
                ? title.trimmingCharacters(in: .whitespacesAndNewlines)
                : fallbackTitle ?? "",
            description: description,
            count: count > 0 ? count : tracks.count,
            artworkURL: artworkURL
                ?? tracks.lazy.compactMap(\.artworkURL).first,
            accessKey: accessKey,
            artists: artists.isEmpty
                ? fallbackArtist.map { [$0] } ?? []
                : Self.uniqueMetadata(artists),
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            isFollowed: isFollowed,
            followHash: followHash
        )
    }

    private static func isUsableMetadata(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.caseInsensitiveCompare("unknown") != .orderedSame
            && trimmed.caseInsensitiveCompare(
                L10n.text("unknown_artist")
            ) != .orderedSame
    }

    private static func uniqueMetadata(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsableMetadata(trimmed) else { return nil }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func mostFrequent(_ values: [String]) -> String? {
        var counts: [String: (value: String, count: Int, order: Int)] = [:]
        for (index, raw) in values.enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if let existing = counts[key] {
                counts[key] = (
                    existing.value,
                    existing.count + 1,
                    existing.order
                )
            } else {
                counts[key] = (value, 1, index)
            }
        }
        return counts.values.max {
            $0.count == $1.count
                ? $0.order > $1.order
                : $0.count < $1.count
        }?.value
    }

    private static func artworkURL(from payload: JSONValue?) -> URL? {
        guard case let .object(object)? = payload else { return nil }

        for key in [
            "photo_1200", "photo_600", "photo_300", "photo_270",
            "photo", "cover_url", "thumb_url", "image"
        ] {
            guard let value = object[key] else { continue }
            if let url = directArtworkURL(from: value) {
                return url
            }
            if let url = bestNestedArtworkURL(from: value) {
                return url
            }
        }

        for key in [
            "thumb", "cover", "thumbs", "photos", "images", "grid"
        ] {
            guard let url = bestNestedArtworkURL(from: object[key]) else {
                continue
            }
            return url
        }

        return nil
    }

    private static func directArtworkURL(from value: JSONValue) -> URL? {
        guard case let .string(raw) = value else { return nil }
        return URL.secureRemoteURL(raw)
    }

    private static func bestNestedArtworkURL(from value: JSONValue?) -> URL? {
        guard let value else { return nil }
        var order = 0
        var candidates: [ArtworkCandidate] = []
        collectArtworkCandidates(
            from: value,
            inheritedSize: nil,
            order: &order,
            into: &candidates
        )
        return candidates.max {
            if $0.size == $1.size {
                return $0.order > $1.order
            }
            return $0.size < $1.size
        }?.url
    }

    private static func collectArtworkCandidates(
        from value: JSONValue,
        inheritedSize: Int?,
        order: inout Int,
        into candidates: inout [ArtworkCandidate]
    ) {
        switch value {
        case let .string(raw):
            appendArtworkCandidate(
                raw,
                size: inheritedSize ?? 0,
                order: &order,
                into: &candidates
            )
        case let .array(values):
            for item in values {
                collectArtworkCandidates(
                    from: item,
                    inheritedSize: inheritedSize,
                    order: &order,
                    into: &candidates
                )
            }
        case let .object(object):
            let objectSize = artworkSizeHint(in: object) ?? inheritedSize
            for key in [
                "photo_1200", "photo_600", "photo_300", "photo_270",
                "photo_135", "photo", "cover_url", "thumb_url",
                "image", "src", "url"
            ] {
                guard case let .string(raw)? = object[key] else { continue }
                appendArtworkCandidate(
                    raw,
                    size: max(
                        artworkSizeHint(fromKey: key) ?? 0,
                        objectSize ?? 0
                    ),
                    order: &order,
                    into: &candidates
                )
            }
            for key in [
                "thumb", "cover", "photo", "thumbs", "photos", "images",
                "image", "grid", "items", "list"
            ] {
                guard let nested = object[key] else { continue }
                collectArtworkCandidates(
                    from: nested,
                    inheritedSize: objectSize,
                    order: &order,
                    into: &candidates
                )
            }
        default:
            break
        }
    }

    private static func appendArtworkCandidate(
        _ raw: String,
        size: Int,
        order: inout Int,
        into candidates: inout [ArtworkCandidate]
    ) {
        defer { order += 1 }
        guard let url = URL.secureRemoteURL(raw) else { return }
        candidates.append(
            ArtworkCandidate(url: url, size: size, order: order)
        )
    }

    private static func artworkSizeHint(in object: [String: JSONValue]) -> Int? {
        [
            numericArtworkValue(object["width"]),
            numericArtworkValue(object["height"]),
            numericArtworkValue(object["size"])
        ]
        .compactMap { $0 }
        .max()
    }

    private static func artworkSizeHint(fromKey key: String) -> Int? {
        guard let suffix = key.split(separator: "_").last,
              let size = Int(suffix) else {
            return nil
        }
        return size
    }

    private static func numericArtworkValue(_ value: JSONValue?) -> Int? {
        switch value {
        case let .number(number)?:
            return Int(number.rounded())
        case let .string(raw)?:
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

enum AlbumShareLinkBuilder {
    static func url(for album: Album) -> URL? {
        var components = URLComponents(
            string: "https://vk.com/music/album/\(album.ownerID)_\(album.albumID)"
        )
        if let accessKey = album.accessKey, !accessKey.isEmpty {
            components?.queryItems = [
                URLQueryItem(name: "access_key", value: accessKey)
            ]
        }
        return components?.url
    }
}
