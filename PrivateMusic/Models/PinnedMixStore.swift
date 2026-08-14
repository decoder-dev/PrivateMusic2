import Foundation

struct PinnedMixSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String { mixID }
    let mixID: String
    let mixTitle: String
    let mixSubtitle: String
    let artworkURL: URL?
    let tracks: [Track]
    let currentIndex: Int
    let elapsed: TimeInterval
    let pinnedAt: Date
    let radioMode: String?

    init(
        mix: MusicMix,
        tracks: [Track],
        currentIndex: Int = 0,
        elapsed: TimeInterval = 0,
        radioMode: MixRadioMode? = nil,
        pinnedAt: Date = Date()
    ) {
        self.mixID = mix.id
        self.mixTitle = mix.title
        self.mixSubtitle = mix.subtitle
        self.artworkURL = mix.artworkURL ?? tracks.first?.artworkURL
        self.tracks = Array(tracks.prefix(MixTrackRequestPolicy.queueLimit))
        self.currentIndex = min(max(currentIndex, 0), max(tracks.count - 1, 0))
        self.elapsed = max(0, elapsed)
        self.pinnedAt = pinnedAt
        self.radioMode = radioMode?.rawValue
    }

    var mix: MusicMix {
        MusicMix(
            id: mixID,
            title: mixTitle,
            subtitle: mixSubtitle,
            artworkURL: artworkURL
        )
    }
}

@MainActor
@Observable
final class PinnedMixStore {
    private(set) var pin: PinnedMixSnapshot?

    private let defaults: UserDefaults
    private var accountID: Int?
    private let keyPrefix = "pinned.mix.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: Int?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        pin = load()
    }

    func pin(
        mix: MusicMix,
        tracks: [Track],
        currentIndex: Int = 0,
        elapsed: TimeInterval = 0,
        radioMode: MixRadioMode? = nil
    ) {
        guard !tracks.isEmpty else { return }
        let snapshot = PinnedMixSnapshot(
            mix: mix,
            tracks: tracks,
            currentIndex: currentIndex,
            elapsed: elapsed,
            radioMode: radioMode
        )
        pin = snapshot
        persist(snapshot)
    }

    func clear() {
        pin = nil
        guard let key = storageKey else { return }
        defaults.removeObject(forKey: key)
    }

    private func load() -> PinnedMixSnapshot? {
        guard let key = storageKey,
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(PinnedMixSnapshot.self, from: data)
    }

    private func persist(_ snapshot: PinnedMixSnapshot) {
        guard let key = storageKey,
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private var storageKey: String? {
        guard let accountID else { return nil }
        return keyPrefix + String(accountID)
    }
}
