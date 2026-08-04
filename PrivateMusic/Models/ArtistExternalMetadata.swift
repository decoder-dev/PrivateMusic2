import Foundation

struct ArtistExternalMetadata: Equatable, Sendable {
    var name: String
    var artworkURL: URL?
    var fanCount: Int?
    var albumCount: Int?
    var biography: String?
    var deezerURL: URL?
    var wikipediaURL: URL?

    var hasEnrichment: Bool {
        artworkURL != nil
            || fanCount != nil
            || albumCount != nil
            || !(biography?.isEmpty ?? true)
    }
}
