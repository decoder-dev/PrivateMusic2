import Foundation

/// Local «не нравится» memory for mix radio — VK's official mix relies on
/// dislikes heavily, but the public API does not expose a feedback method.
/// Persist bans per account so the same stuck artists stop resurfacing.
@MainActor
final class MixFeedbackStore: ObservableObject {
    @Published private(set) var bannedTrackIDs: Set<String> = []
    @Published private(set) var bannedArtists: Set<String> = []

    private let defaults: UserDefaults
    private var accountID: Int?
    private let keyPrefix = "mix.feedback.v1."

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

    /// Ban a track. When `includeArtist` is true, also suppress that artist
    /// across future mix fills (closest analogue to VK's strong dislike).
    func ban(_ track: Track, includeArtist: Bool = false) {
        bannedTrackIDs.insert(track.id)
        if includeArtist {
            let artist = MixFeedbackPolicy.normalized(track.artist)
            if !artist.isEmpty {
                bannedArtists.insert(artist)
            }
        }
        persist()
    }

    func clear() {
        bannedTrackIDs = []
        bannedArtists = []
        persist()
    }

    private var storageKey: String? {
        guard let accountID else { return nil }
        return keyPrefix + String(accountID)
    }

    private func load() {
        guard let storageKey,
              let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                Snapshot.self,
                from: data
              ) else {
            bannedTrackIDs = []
            bannedArtists = []
            return
        }
        bannedTrackIDs = Set(decoded.trackIDs)
        bannedArtists = Set(decoded.artists.map(MixFeedbackPolicy.normalized))
    }

    private func persist() {
        guard let storageKey else { return }
        let snapshot = Snapshot(
            trackIDs: Array(bannedTrackIDs).sorted(),
            artists: Array(bannedArtists).sorted()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private struct Snapshot: Codable {
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
