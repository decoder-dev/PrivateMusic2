import Foundation

/// Cross-launch memory for Home's dynamic-artist section — just enough to
/// keep it from reshuffling after every track. Scoped per account and
/// persisted the same way `PinnedMixStore` and `MixFeedbackStore` already
/// are: a small Codable snapshot in `UserDefaults`, not a new persistence
/// layer.
@MainActor
@Observable
final class HomePersonalizationStore {
    private(set) var lastShownArtistKey: String?

    private let defaults: UserDefaults
    private var accountID: Int?
    private let keyPrefix = "home.personalization.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: Int?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        load()
    }

    /// Records which artist the dynamic section is currently showing, so a
    /// later recompute with a marginally different score does not swap it
    /// out immediately.
    func recordShown(artistKey: String) {
        guard artistKey != lastShownArtistKey else { return }
        lastShownArtistKey = artistKey
        persist()
    }

    /// Clears the remembered artist once it no longer qualifies at all, so
    /// a future recompute starts fresh instead of sticking to a name that
    /// can never come back.
    func clearIfShowing(artistKey: String) {
        guard lastShownArtistKey == artistKey else { return }
        lastShownArtistKey = nil
        persist()
    }

    private var storageKey: String? {
        guard let accountID else { return nil }
        return keyPrefix + String(accountID)
    }

    private func load() {
        guard let storageKey,
              let stored = defaults.string(forKey: storageKey) else {
            lastShownArtistKey = nil
            return
        }
        lastShownArtistKey = stored
    }

    private func persist() {
        guard let storageKey else { return }
        if let lastShownArtistKey {
            defaults.set(lastShownArtistKey, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}
