import Foundation

/// Remembers the What's Next winner (and its artist, when relevant) so
/// Home does not reshuffle the slot after every track. Scoped per account
/// and persisted the same way `PinnedMixStore` and `MixFeedbackStore`
/// already are.
@MainActor
@Observable
final class HomePersonalizationStore {
    private(set) var lastShownArtistKey: String?
    private(set) var lastShownNextStepKey: String?

    private let defaults: UserDefaults
    private var accountID: Int?
    private let keyPrefix = "home.personalization.v1."
    private let nextStepKeyPrefix = "home.nextstep.v1."

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

    func recordShownNextStep(key: String) {
        guard key != lastShownNextStepKey else { return }
        lastShownNextStepKey = key
        persistNextStep()
    }

    func clearNextStepIfShowing(key: String) {
        guard lastShownNextStepKey == key else { return }
        lastShownNextStepKey = nil
        persistNextStep()
    }

    private var storageKey: String? {
        guard let accountID else { return nil }
        return keyPrefix + String(accountID)
    }

    private var nextStepStorageKey: String? {
        guard let accountID else { return nil }
        return nextStepKeyPrefix + String(accountID)
    }

    private func load() {
        guard let storageKey,
              let stored = defaults.string(forKey: storageKey) else {
            lastShownArtistKey = nil
            lastShownNextStepKey = loadNextStep()
            return
        }
        lastShownArtistKey = stored
        lastShownNextStepKey = loadNextStep()
    }

    private func loadNextStep() -> String? {
        guard let nextStepStorageKey else { return nil }
        return defaults.string(forKey: nextStepStorageKey)
    }

    private func persist() {
        guard let storageKey else { return }
        if let lastShownArtistKey {
            defaults.set(lastShownArtistKey, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func persistNextStep() {
        guard let nextStepStorageKey else { return }
        if let lastShownNextStepKey {
            defaults.set(lastShownNextStepKey, forKey: nextStepStorageKey)
        } else {
            defaults.removeObject(forKey: nextStepStorageKey)
        }
    }
}
