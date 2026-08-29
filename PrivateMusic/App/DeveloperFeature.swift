import Foundation

/// Hidden developer tools (log archive export, diagnostics). Unlocked from
/// Settings → About by tapping the version row repeatedly.
enum DeveloperFeature {
    static let requiredVersionTaps = 7

    private static let defaults = UserDefaults.standard

    static var isUnlocked: Bool {
        defaults.bool(forKey: Keys.unlocked)
    }

    static var versionTapCount: Int {
        defaults.integer(forKey: Keys.versionTapCount)
    }

    /// Records one version-row tap. Returns `true` when the menu unlocks on
    /// this tap.
    @discardableResult
    static func registerVersionTap() -> Bool {
        guard !isUnlocked else { return false }
        let next = versionTapCount + 1
        defaults.set(next, forKey: Keys.versionTapCount)
        if next >= requiredVersionTaps {
            defaults.set(true, forKey: Keys.unlocked)
            AppLog.shared.setFileLoggingEnabled(true)
            AppLog.shared.setVerbose(true)
            AppLog.shared.info(.app, "Developer menu unlocked")
            return true
        }
        return false
    }

    #if DEBUG
    static func resetForTesting() {
        defaults.removeObject(forKey: Keys.unlocked)
        defaults.removeObject(forKey: Keys.versionTapCount)
    }
    #endif

    private enum Keys {
        static let unlocked = "developer.menu.unlocked"
        static let versionTapCount = "developer.menu.versionTapCount"
    }
}

/// Pure tap counter for unit tests.
enum DeveloperUnlockPolicy {
    static func nextTapCount(
        _ current: Int,
        required: Int = DeveloperFeature.requiredVersionTaps
    ) -> (taps: Int, unlocked: Bool) {
        let taps = current + 1
        return (taps, taps >= required)
    }
}
