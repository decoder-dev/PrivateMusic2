import Foundation

/// Account-scoped collection identities and small metadata snapshots for offline launches.
@MainActor
@Observable
final class PinnedCollectionsStore {
    static let limit = 24
    private(set) var identities: [String] = []
    private(set) var playlistSnapshots: [Playlist] = []
    private(set) var albumSnapshots: [Album] = []
    private struct Snapshot: Codable {
        let identities: [String]
        let playlists: [Playlist]
        let albums: [Album]
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
        albumSnapshots = snapshot?.albums ?? []
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
        if let data = try? JSONEncoder().encode(Snapshot(identities: identities, playlists: playlistSnapshots, albums: albumSnapshots)) {
            defaults.set(data, forKey: key)
        }
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
