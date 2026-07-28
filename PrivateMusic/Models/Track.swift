import Foundation

struct Track: Codable, Hashable, Identifiable, Sendable {
    let trackID: Int
    let ownerID: Int
    let title: String
    let artist: String
    let albumTitle: String?
    let duration: TimeInterval
    let streamURL: URL?
    let artworkURL: URL?
    let accessKey: String?
    let lyricsID: Int?

    var id: String { "\(ownerID)_\(trackID)" }

    init(
        trackID: Int,
        ownerID: Int,
        title: String,
        artist: String,
        albumTitle: String? = nil,
        duration: TimeInterval,
        streamURL: URL?,
        artworkURL: URL?,
        accessKey: String? = nil,
        lyricsID: Int? = nil
    ) {
        self.trackID = trackID
        self.ownerID = ownerID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.accessKey = accessKey
        self.lyricsID = lyricsID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case artist
        case albumTitle = "album_title"
        case duration
        case url
        case album
        case accessKey = "access_key"
        case lyricsID = "lyrics_id"
    }

    enum AlbumKeys: String, CodingKey {
        case thumb
        case title
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
        albumTitle = try container.decodeIfPresent(
            String.self,
            forKey: .albumTitle
        ) ?? (try? container.nestedContainer(
            keyedBy: AlbumKeys.self,
            forKey: .album
        ).decodeIfPresent(String.self, forKey: .title)) ?? nil
        duration = TimeInterval(
            try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        )
        let stream = try container.decodeIfPresent(String.self, forKey: .url)
        streamURL = stream.flatMap(URL.secureRemoteURL)
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)
        lyricsID = try container.decodeIfPresent(Int.self, forKey: .lyricsID)

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
        try container.encodeIfPresent(albumTitle, forKey: .albumTitle)
        try container.encode(Int(duration), forKey: .duration)
        try container.encodeIfPresent(streamURL?.absoluteString, forKey: .url)
        try container.encodeIfPresent(accessKey, forKey: .accessKey)
        try container.encodeIfPresent(lyricsID, forKey: .lyricsID)
    }

    func resolvingStreamURL(userID: Int?) -> Track {
        Track(
            trackID: trackID,
            ownerID: ownerID,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            duration: duration,
            streamURL: VKAudioURLResolver.resolve(
                streamURL,
                userID: userID
            ),
            artworkURL: artworkURL,
            accessKey: accessKey,
            lyricsID: lyricsID
        )
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
