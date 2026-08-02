import Foundation

/// Temporary kill-switch for offline downloads / auto-cache / playlist
/// offline packaging. Share remains available; already-saved local files
/// can still play. Flip `productionEnabled` to `true` when download UX is
/// ready again after vacation.
enum OfflineDownloadsFeature {
    private static let productionEnabled = false

    /// Test seam so offline unit tests can exercise the download stack while
    /// production builds keep downloads hidden.
    static var testingOverride: Bool?

    static var isEnabled: Bool {
        testingOverride ?? productionEnabled
    }

    static var showsControls: Bool { isEnabled }
}
