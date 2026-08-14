import Foundation

/// Kill-switch for offline downloads / auto-cache / playlist offline
/// packaging. Share remains available; already-saved local files can
/// still play. Flip `productionEnabled` to hide the download UI again.
enum OfflineDownloadsFeature {
    private static let productionEnabled = true

    /// Test seam so offline unit tests can exercise the download stack while
    /// production builds keep downloads hidden.
    nonisolated(unsafe) static var testingOverride: Bool?

    static var isEnabled: Bool {
        testingOverride ?? productionEnabled
    }

    static var showsControls: Bool { isEnabled }
}
