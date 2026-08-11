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
    let albumReference: AlbumReference?
    /// VK `is_hq` flag when present — progressive HQ / preferred encode.
    let isHQ: Bool

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
        lyricsID: Int? = nil,
        albumReference: AlbumReference? = nil,
        isHQ: Bool = false
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
        self.albumReference = albumReference
        self.isHQ = isHQ
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
        case albumID = "album_id"
        case accessKey = "access_key"
        case lyricsID = "lyrics_id"
        case isHQ = "is_hq"
    }

    enum AlbumKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case accessKey = "access_key"
        case thumb, photo
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
        // VK sends `is_hq` as 0/1 more often than a JSON bool.
        if let number = try? container.decode(Int.self, forKey: .isHQ) {
            isHQ = number != 0
        } else if let flag = try? container.decode(Bool.self, forKey: .isHQ) {
            isHQ = flag
        } else {
            isHQ = false
        }

        if let album = try? container.nestedContainer(
            keyedBy: AlbumKeys.self,
            forKey: .album
        ) {
            let thumb = try? album.nestedContainer(
                keyedBy: ThumbKeys.self,
                forKey: .thumb
            )
            let photo = try? album.nestedContainer(
                keyedBy: ThumbKeys.self,
                forKey: .photo
            )
            var raw: String?
            if let thumb {
                raw = try thumb.decodeIfPresent(
                    String.self,
                    forKey: .photo600
                )
                if raw == nil {
                    raw = try thumb.decodeIfPresent(
                        String.self,
                        forKey: .photo300
                    )
                }
                if raw == nil {
                    raw = try thumb.decodeIfPresent(
                        String.self,
                        forKey: .photo270
                    )
                }
            }
            if raw == nil, let photo {
                raw = try photo.decodeIfPresent(
                    String.self,
                    forKey: .photo600
                )
                if raw == nil {
                    raw = try photo.decodeIfPresent(
                        String.self,
                        forKey: .photo300
                    )
                }
                if raw == nil {
                    raw = try photo.decodeIfPresent(
                        String.self,
                        forKey: .photo270
                    )
                }
            }
            artworkURL = raw.flatMap(URL.secureRemoteURL)
        } else {
            artworkURL = nil
        }
        let nestedAlbum = try? container.nestedContainer(
            keyedBy: AlbumKeys.self,
            forKey: .album
        )
        let nestedAlbumID = try nestedAlbum?.decodeIfPresent(
            Int.self,
            forKey: .id
        )
        let nestedOwnerID = try nestedAlbum?.decodeIfPresent(
            Int.self,
            forKey: .ownerID
        )
        if let albumID = nestedAlbumID,
           let albumOwnerID = nestedOwnerID {
            albumReference = AlbumReference(
                albumID: albumID,
                ownerID: albumOwnerID,
                accessKey: try nestedAlbum?.decodeIfPresent(
                    String.self,
                    forKey: .accessKey
                )
            )
        } else {
            // A top-level album_id or nested id without owner_id is not a
            // complete playlist locator. The audio owner can differ from the
            // album owner, so CatalogView must resolve it by title instead.
            albumReference = nil
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
        if isHQ {
            try container.encode(true, forKey: .isHQ)
        }
        try container.encodeIfPresent(
            albumReference?.albumID,
            forKey: .albumID
        )
        if albumTitle != nil || albumReference != nil || artworkURL != nil {
            var album = container.nestedContainer(
                keyedBy: AlbumKeys.self,
                forKey: .album
            )
            try album.encodeIfPresent(albumTitle, forKey: .title)
            try album.encodeIfPresent(albumReference?.albumID, forKey: .id)
            try album.encodeIfPresent(
                albumReference?.ownerID,
                forKey: .ownerID
            )
            try album.encodeIfPresent(
                albumReference?.accessKey,
                forKey: .accessKey
            )
            if let artworkURL {
                var thumb = album.nestedContainer(
                    keyedBy: ThumbKeys.self,
                    forKey: .thumb
                )
                try thumb.encode(
                    artworkURL.absoluteString,
                    forKey: .photo600
                )
            }
        }
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
            lyricsID: lyricsID,
            albumReference: albumReference,
            isHQ: isHQ
        )
    }
}

extension URL {
    static func secureRemoteURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let schemed = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard var components = URLComponents(string: schemed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            return nil
        }
        switch scheme {
        case "https":
            break
        case "http":
            components.scheme = "https"
        default:
            return nil
        }
        return components.url
    }
}
