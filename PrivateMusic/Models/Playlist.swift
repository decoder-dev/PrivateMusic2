import Foundation

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let ownerID: Int
    let title: String
    let description: String?
    let count: Int
    let artworkURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case title
        case description
        case count
        case artworkURL = "artwork_url"
    }
}
