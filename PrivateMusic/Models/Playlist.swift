import Foundation

enum PlaylistSource: String, Codable, Hashable, Sendable {
    case vk

    var title: String {
        switch self {
        case .vk: L10n.text("VK Музыка")
        }
    }

    var shortTitle: String {
        switch self {
        case .vk: "VK"
        }
    }
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let ownerID: Int
    let title: String
    let description: String?
    let count: Int
    let artworkURL: URL?
    let accessKey: String?

    var source: PlaylistSource { .vk }

    /// Returns a copy with a refreshed track count. Used after the offline
    /// download resolves the real track list so the stored playlist metadata
    /// never keeps a stale `count == 0`.
    func updatingCount(_ newCount: Int) -> Playlist {
        Playlist(
            id: id,
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
        self.id = id
        self.ownerID = ownerID
        self.title = title
        self.description = description
        self.count = count
        self.artworkURL = artworkURL
        self.accessKey = accessKey
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case description
        case count
        case photo600 = "photo_600"
        case photo300 = "photo_300"
        case accessKey = "access_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        ownerID = try container.decode(Int.self, forKey: .ownerID)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(
            String.self,
            forKey: .description
        )
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        accessKey = try container.decodeIfPresent(
            String.self,
            forKey: .accessKey
        )
        let rawArtwork = try container.decodeIfPresent(
            String.self,
            forKey: .photo600
        ) ?? container.decodeIfPresent(String.self, forKey: .photo300)
        artworkURL = rawArtwork.flatMap(URL.secureRemoteURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
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
