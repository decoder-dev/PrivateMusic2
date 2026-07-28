import Foundation

struct Track: Codable, Hashable, Identifiable, Sendable {
    let trackID: Int
    let ownerID: Int
    let title: String
    let artist: String
    let duration: TimeInterval
    let streamURL: URL?
    let artworkURL: URL?
    let accessKey: String?

    var id: String { "\(ownerID)_\(trackID)" }

    init(
        trackID: Int,
        ownerID: Int,
        title: String,
        artist: String,
        duration: TimeInterval,
        streamURL: URL?,
        artworkURL: URL?,
        accessKey: String? = nil
    ) {
        self.trackID = trackID
        self.ownerID = ownerID
        self.title = title
        self.artist = artist
        self.duration = duration
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.accessKey = accessKey
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case artist
        case duration
        case url
        case album
        case accessKey = "access_key"
    }

    enum AlbumKeys: String, CodingKey {
        case thumb
    }

    enum ThumbKeys: String, CodingKey {
        case photo600 = "photo_600"
        case photo300 = "photo_300"
        case photo270 = "photo_270"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(Int.self, forKey: .id)
        ownerID = try container.decode(Int.self, forKey: .ownerID)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        duration = TimeInterval(
            try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        )
        let stream = try container.decodeIfPresent(String.self, forKey: .url)
        streamURL = stream.flatMap(URL.secureRemoteURL)
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)

        if let album = try? container.nestedContainer(
            keyedBy: AlbumKeys.self,
            forKey: .album
        ), let thumb = try? album.nestedContainer(
            keyedBy: ThumbKeys.self,
            forKey: .thumb
        ) {
            let raw = try thumb.decodeIfPresent(String.self, forKey: .photo600)
                ?? thumb.decodeIfPresent(String.self, forKey: .photo300)
                ?? thumb.decodeIfPresent(String.self, forKey: .photo270)
            artworkURL = raw.flatMap(URL.secureRemoteURL)
        } else {
            artworkURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackID, forKey: .id)
        try container.encode(ownerID, forKey: .ownerID)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(Int(duration), forKey: .duration)
        try container.encodeIfPresent(streamURL?.absoluteString, forKey: .url)
        try container.encodeIfPresent(accessKey, forKey: .accessKey)
    }
}

extension URL {
    static func secureRemoteURL(_ rawValue: String) -> URL? {
        guard !rawValue.isEmpty,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
