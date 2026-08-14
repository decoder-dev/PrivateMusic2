import Foundation

/// Kill-switch for offline downloads / auto-cache / playlist offline
/// packaging. Share remains available; already-saved local files can
/// still play. Flip `productionEnabled` to hide the download UI again.
enum OfflineDownloadsFeature {
    private static let productionEnabled = true

    /// Test seam so offline unit tests can exercise the download stack while
    /// production builds keep downloads hidden.
    private static let testingLock = NSLock()
    private static var _testingOverride: Bool?

    static var testingOverride: Bool? {
        get { testingLock.withLock { _testingOverride } }
        set { testingLock.withLock { _testingOverride = newValue } }
    }

    static var isEnabled: Bool {
        testingOverride ?? productionEnabled
    }

    static var showsControls: Bool { isEnabled }
}
