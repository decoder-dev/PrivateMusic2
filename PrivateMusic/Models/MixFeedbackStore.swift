import Foundation

struct BannedTrackRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
}

struct BannedArtistRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let displayName: String
}

/// Local «не нравится» memory for mix radio — VK's official mix relies on
/// dislikes heavily, but the public API does not expose a feedback method.
@MainActor
@Observable
final class MixFeedbackStore {
    private(set) var bannedTracks: [BannedTrackRecord] = []
    private(set) var bannedArtistRecords: [BannedArtistRecord] = []

    var bannedTrackIDs: Set<String> { Set(bannedTracks.map(\.id)) }
    var bannedArtists: Set<String> { Set(bannedArtistRecords.map(\.key)) }

    private let defaults: UserDefaults
    private var accountID: Int?
    private let keyPrefix = "mix.feedback.v2."
    private let legacyKeyPrefix = "mix.feedback.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: Int?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        load()
    }

    func isBanned(_ track: Track) -> Bool {
        MixFeedbackPolicy.isBanned(
            track,
            trackIDs: bannedTrackIDs,
            artists: bannedArtists
        )
    }

    func filtering(_ tracks: [Track]) -> [Track] {
        MixFeedbackPolicy.filtering(
            tracks,
            trackIDs: bannedTrackIDs,
            artists: bannedArtists
        )
    }

    func ban(_ track: Track, includeArtist: Bool = false) {
        if !bannedTracks.contains(where: { $0.id == track.id }) {
            bannedTracks.append(
                BannedTrackRecord(
                    id: track.id,
                    title: track.title,
                    artist: track.artist
                )
            )
        }
        if includeArtist {
            let key = MixFeedbackPolicy.normalized(track.artist)
            if !key.isEmpty,
               !bannedArtistRecords.contains(where: { $0.key == key }) {
                bannedArtistRecords.append(
                    BannedArtistRecord(
                        key: key,
                        displayName: track.artist
                    )
                )
            }
        }
        persist()
    }

    func unbanTrack(id: String) {
        bannedTracks.removeAll { $0.id == id }
        persist()
    }

    func unbanArtist(key: String) {
        let normalized = MixFeedbackPolicy.normalized(key)
        bannedArtistRecords.removeAll { $0.key == normalized }
        persist()
    }

    func clear() {
        bannedTracks = []
        bannedArtistRecords = []
        persist()
    }

    private var storageKey: String? {
        guard let accountID else { return nil }
        return keyPrefix + String(accountID)
    }

    private var legacyStorageKey: String? {
        guard let accountID else { return nil }
        return legacyKeyPrefix + String(accountID)
    }

    private func load() {
        if let storageKey,
           let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            bannedTracks = decoded.tracks
            bannedArtistRecords = decoded.artists
            return
        }
        // Migrate v1 id/artist string sets.
        if let legacyStorageKey,
           let data = defaults.data(forKey: legacyStorageKey),
           let legacy = try? JSONDecoder().decode(
            LegacySnapshot.self,
            from: data
           ) {
            bannedTracks = legacy.trackIDs.map {
                BannedTrackRecord(id: $0, title: $0, artist: "")
            }
            bannedArtistRecords = legacy.artists.map {
                let key = MixFeedbackPolicy.normalized($0)
                return BannedArtistRecord(key: key, displayName: $0)
            }
            persist()
            return
        }
        bannedTracks = []
        bannedArtistRecords = []
    }

    private func persist() {
        guard let storageKey else { return }
        let snapshot = Snapshot(
            tracks: bannedTracks,
            artists: bannedArtistRecords
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private struct Snapshot: Codable {
        let tracks: [BannedTrackRecord]
        let artists: [BannedArtistRecord]
    }

    private struct LegacySnapshot: Codable {
        let trackIDs: [String]
        let artists: [String]
    }
}

enum MixFeedbackPolicy {
    static func isBanned(
        _ track: Track,
        trackIDs: Set<String>,
        artists: Set<String>
    ) -> Bool {
        if trackIDs.contains(track.id) { return true }
        let artist = normalized(track.artist)
        return !artist.isEmpty && artists.contains(artist)
    }

    static func filtering(
        _ tracks: [Track],
        trackIDs: Set<String>,
        artists: Set<String>
    ) -> [Track] {
        tracks.filter {
            !isBanned($0, trackIDs: trackIDs, artists: artists)
        }
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
