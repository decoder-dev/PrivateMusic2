import Foundation

/// How the queue that is about to start should be ordered.
enum PlaybackShuffleIntent: Equatable, Sendable {
    /// Follow the player's shuffle control. Everything that plays a visible
    /// list — Медиатека, a playlist, an album, search results — uses this,
    /// so with shuffle off the queue is the list, in the list's order.
    case followPreference

    /// Per-collection «Перемешать». Shuffles the queue it starts and
    /// nothing else.
    case shuffleCollection
}

/// The persisted shuffle preference, kept apart from the shuffle mode of
/// whatever queue happens to be playing.
///
/// Mixing the two is what kept Медиатека out of order. «Перемешать» on an
/// album, a playlist or a mix turned the player-wide flag on, and every
/// later queue — including a tap on a liked track in the library — was
/// built from it.
enum PlaybackShufflePreference {
    static let key = "player.shuffle"

    /// One-shot marker for the migration below.
    static let collectionLatchClearedKey =
        "player.shuffle.collectionLatchCleared.v1"

    /// Reads the stored preference, clearing once the value that
    /// per-collection «Перемешать» used to persist.
    ///
    /// Builds up to 3.28.62 wrote `player.shuffle` straight from the
    /// album/playlist shuffle button, so one tap latched shuffle on for
    /// every later queue and survived relaunch. Those installs still carry
    /// the latched `true`, which is why Медиатека went on playing «в
    /// разнобой» after the button itself stopped persisting. Clear it once;
    /// what the user sets from the player control afterwards persists
    /// normally.
    static func resolve(defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: collectionLatchClearedKey) else {
            return defaults.bool(forKey: key)
        }
        defaults.set(true, forKey: collectionLatchClearedKey)
        defaults.set(false, forKey: key)
        return false
    }

    static func store(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: key)
        defaults.set(true, forKey: collectionLatchClearedKey)
    }
}
