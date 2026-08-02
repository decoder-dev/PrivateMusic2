import Foundation

struct Album: Decodable, Hashable, Identifiable, Sendable {
    struct Artist: Decodable, Hashable, Sendable {
        let name: String
    }

    private struct Artwork: Decodable {
        let photo600: String?
        let photo300: String?
        let photo270: String?

        enum CodingKeys: String, CodingKey {
            case photo600 = "photo_600"
            case photo300 = "photo_300"
            case photo270 = "photo_270"
        }
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
    let isFollowed: Bool
    let followHash: String?

    var id: String { compositeID }
    var compositeID: String { "\(ownerID)_\(albumID)" }
    var artistText: String {
        artists.isEmpty ? L10n.text("Неизвестный исполнитель") : artists.joined(separator: ", ")
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
            isFollowed: followed,
            followHash: followHash
        )
    }

    enum CodingKeys: String, CodingKey {
        case albumID = "id"
        case title, description, count, size, year
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
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
            ?? container.decodeIfPresent(Int.self, forKey: .size)
            ?? 0
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)
        artists = (try? container.decode([Artist].self, forKey: .mainArtists))?
            .map(\.name) ?? []
        let followedBool = try? container.decode(Bool.self, forKey: .isFollowed)
        let followedInteger =
            (try? container.decode(Int.self, forKey: .isFollowed)) == 1
            || (try? container.decode(Int.self, forKey: .followed)) == 1
        isFollowed = followedBool ?? followedInteger
        followHash = try container.decodeIfPresent(String.self, forKey: .followHash)
        let nestedArtwork = try container.decodeIfPresent(
            Artwork.self,
            forKey: .thumb
        )
        let rawArtwork = try container.decodeIfPresent(String.self, forKey: .photo600)
            ?? container.decodeIfPresent(String.self, forKey: .photo300)
            ?? container.decodeIfPresent(String.self, forKey: .photo270)
            ?? nestedArtwork?.photo600
            ?? nestedArtwork?.photo300
            ?? nestedArtwork?.photo270
        artworkURL = rawArtwork.flatMap(URL.secureRemoteURL)
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
            releaseDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else if let raw = stringReleaseDate,
                  let timestamp = Int(raw),
                  timestamp > 10_000 {
            releaseDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else if let raw = stringReleaseDate,
                  let parsed = ISO8601DateFormatter().date(from: raw) {
            releaseDate = parsed
        } else if let year = try container.decodeIfPresent(Int.self, forKey: .year),
                  (1900...2200).contains(year) {
            releaseDate = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: 1, day: 1)
            )
        } else {
            releaseDate = nil
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
