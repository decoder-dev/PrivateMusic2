import Foundation

/// Account-scoped collection identities and small metadata snapshots for offline launches.
@MainActor
@Observable
final class PinnedCollectionsStore {
    static let limit = 24
    private(set) var identities: [String] = []
    private(set) var playlistSnapshots: [Playlist] = []
    private(set) var albumSnapshots: [Album] = []
    /// API albums decode VK's schema; the local format uses its own symmetric codec.
    private struct StoredAlbum: Codable {
        let id: Int
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

        init(_ album: Album) {
            id = album.albumID; ownerID = album.ownerID; title = album.title
            description = album.description; count = album.count; artworkURL = album.artworkURL
            accessKey = album.accessKey; artists = album.artists; releaseDate = album.releaseDate
            releaseYear = album.releaseYear; isFollowed = album.isFollowed; followHash = album.followHash
        }

        var album: Album {
            Album(id: id, ownerID: ownerID, title: title, description: description, count: count,
                  artworkURL: artworkURL, accessKey: accessKey, artists: artists, releaseDate: releaseDate,
                  releaseYear: releaseYear, isFollowed: isFollowed, followHash: followHash)
        }
    }

    private struct Snapshot: Codable {
        let identities: [String]
        let playlists: [Playlist]
        let albums: [StoredAlbum]
    }
    private let defaults: UserDefaults
    private var accountID: Int?
    private var key: String? { accountID.map { "library.pins.v1.\($0)" } }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func playlistKey(_ playlist: Playlist) -> String { "playlist:" + playlist.libraryIdentity }
    static func albumKey(_ album: Album) -> String { "album:" + album.compositeID }

    func configure(accountID: Int?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        let snapshot = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        let stored = snapshot?.identities ?? key.flatMap { defaults.stringArray(forKey: $0) } ?? []
        playlistSnapshots = snapshot?.playlists ?? []
        albumSnapshots = snapshot?.albums.map(\.album) ?? []
        var seen = Set<String>()
        identities = Array(stored.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    func contains(_ identity: String) -> Bool { identities.contains(identity) }

    func toggle(_ identity: String) {
        guard let key else { return }
        if contains(identity) { identities.removeAll { $0 == identity } }
        else {
            guard identities.count < Self.limit else { return }
            identities.insert(identity, at: 0)
        }
        playlistSnapshots.removeAll { !identities.contains(Self.playlistKey($0)) }
        albumSnapshots.removeAll { !identities.contains(Self.albumKey($0)) }
        persist(key: key)
    }

    func toggle(playlist: Playlist) {
        let identity = Self.playlistKey(playlist)
        let adding = !contains(identity)
        toggle(identity)
        if adding, contains(identity) {
            playlistSnapshots.removeAll { Self.playlistKey($0) == identity }
            playlistSnapshots.append(playlist)
            if let key { persist(key: key) }
        }
    }

    func toggle(album: Album) {
        let identity = Self.albumKey(album)
        let adding = !contains(identity)
        toggle(identity)
        if adding, contains(identity) {
            albumSnapshots.removeAll { Self.albumKey($0) == identity }
            albumSnapshots.append(album)
            if let key { persist(key: key) }
        }
    }

    private func persist(key: String) {
        if let data = try? JSONEncoder().encode(Snapshot(identities: identities, playlists: playlistSnapshots, albums: albumSnapshots.map(StoredAlbum.init))) {
            defaults.set(data, forKey: key)
        }
    }

    func availablePlaylists(_ live: [Playlist]) -> [Playlist] {
        let ids = Set(live.map(\.libraryIdentity))
        return live + playlistSnapshots.filter { !ids.contains($0.libraryIdentity) && contains(Self.playlistKey($0)) }
    }

    func availableAlbums(_ live: [Album]) -> [Album] {
        let ids = Set(live.map(\.compositeID))
        return live + albumSnapshots.filter { !ids.contains($0.compositeID) && contains(Self.albumKey($0)) }
    }

    func ordered<T>(_ values: [T], identity: (T) -> String) -> [T] {
        let ranks = Dictionary(uniqueKeysWithValues: identities.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted {
            let a = ranks[identity($0.element)] ?? Int.max
            let b = ranks[identity($1.element)] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}
