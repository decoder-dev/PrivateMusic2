import Foundation

enum PlaylistSource: String, Codable, Hashable, Sendable {
    case vk

    var title: String {
        switch self {
        case .vk: L10n.text("vk_music")
        }
    }

    var shortTitle: String {
        switch self {
        case .vk: "VK"
        }
    }
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    let playlistID: Int
    let ownerID: Int
    let title: String
    let description: String?
    let count: Int
    let artworkURL: URL?
    let accessKey: String?

    /// VK playlist ids are only unique per owner: `audio.getPlaylists`
    /// with `filters=owned,followed` returns other people's playlists whose
    /// numeric id can collide with one of yours. Identifying a list row by
    /// the bare id hands SwiftUI duplicate `ForEach` ids, which renders the
    /// library shelf as undefined, collapsed cards.
    var id: String { libraryIdentity }
    var libraryIdentity: String { "\(ownerID)_\(playlistID)" }

    var source: PlaylistSource { .vk }

    /// Returns a copy with a refreshed track count. Used after the offline
    /// download resolves the real track list so the stored playlist metadata
    /// never keeps a stale `count == 0`.
    func updatingCount(_ newCount: Int) -> Playlist {
        Playlist(
            id: playlistID,
            ownerID: ownerID,
            title: title,
            description: description,
            count: newCount,
            artworkURL: artworkURL,
            accessKey: accessKey
        )
    }

    /// Explicit memberwise initializer. `init(from:)` suppresses the
    /// synthesized one, and the offline store builds copies with a refreshed
    /// track count.
    init(
        id: Int,
        ownerID: Int,
        title: String,
        description: String? = nil,
        count: Int,
        artworkURL: URL? = nil,
        accessKey: String? = nil
    ) {
        self.playlistID = id
        self.ownerID = ownerID
        self.title = title
        self.description = description
        self.count = count
        self.artworkURL = artworkURL
        self.accessKey = accessKey
    }

    enum CodingKeys: String, CodingKey {
        case playlistID = "id"
        case ownerID = "owner_id"
        case title
        case description
        case count
        case photo1200 = "photo_1200"
        case photo600 = "photo_600"
        case photo300 = "photo_300"
        case photo270 = "photo_270"
        case photo
        case thumb
        case thumbs
        case accessKey = "access_key"
    }

    private struct Thumb: Decodable {
        let photo1200: String?
        let photo600: String?
        let photo300: String?
        let photo270: String?

        var bestPhoto: String? {
            photo1200 ?? photo600 ?? photo300 ?? photo270
        }

        enum CodingKeys: String, CodingKey {
            case photo1200 = "photo_1200"
            case photo600 = "photo_600"
            case photo300 = "photo_300"
            case photo270 = "photo_270"
        }
    }

    /// VK is not consistent about whether an id arrives as a number or as a
    /// string, and a strict `Int` decode threw the whole entry away.
    private static func integer(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let raw = try? container.decode(String.self, forKey: key) {
            return Int(raw)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Self.integer(in: container, forKey: .playlistID),
              let owner = Self.integer(in: container, forKey: .ownerID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .playlistID,
                in: container,
                debugDescription: "Playlist entry without an owner-scoped id"
            )
        }
        playlistID = id
        ownerID = owner
        // An untitled playlist is still a playlist. Requiring a title here
        // is what made one arrive on the shelf as nothing at all.
        title = (
            try? container.decode(String.self, forKey: .title)
        ) ?? L10n.text("playlist")
        description = try container.decodeIfPresent(
            String.self,
            forKey: .description
        )
        count = Self.integer(in: container, forKey: .count) ?? 0
        accessKey = try container.decodeIfPresent(
            String.self,
            forKey: .accessKey
        )
        var rawArtwork: String?
        for key in [
            CodingKeys.photo1200, .photo600, .photo300, .photo270
        ] {
            rawArtwork = try? container.decode(String.self, forKey: key)
            if rawArtwork != nil { break }
        }
        if rawArtwork == nil {
            for key in [CodingKeys.thumb, .photo] {
                let thumb: Thumb? = try? container.decode(
                    Thumb.self,
                    forKey: key
                )
                rawArtwork = thumb?.bestPhoto
                if rawArtwork != nil { break }
            }
        }
        if rawArtwork == nil {
            // Playlists without an uploaded cover (including the system
            // «Мне нравится») ship a generated mosaic under `thumbs`, not
            // `photo_*`. Missing it left those cards as bare text.
            let thumbs: [Thumb] = (
                try? container.decode([Thumb].self, forKey: .thumbs)
            ) ?? []
            rawArtwork = thumbs.lazy.compactMap(\.bestPhoto).first
        }
        artworkURL = rawArtwork.flatMap(URL.secureRemoteURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playlistID, forKey: .playlistID)
        try container.encode(ownerID, forKey: .ownerID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(count, forKey: .count)
        try container.encodeIfPresent(
            artworkURL?.absoluteString,
            forKey: .photo600
        )
        try container.encodeIfPresent(accessKey, forKey: .accessKey)
    }
}
