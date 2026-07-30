import XCTest
@testable import PrivateMusic

@MainActor
final class AppSettingsOfflineTests: XCTestCase {
    func testOfflineDefaultsAreConservative() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.offlineStorageLimitGB, 5)
            XCTAssertEqual(settings.offlineStorageLimitBytes, 5_000_000_000)
            XCTAssertFalse(settings.automaticOfflineCacheEnabled)
        }
    }

    func testOfflinePreferencesPersist() {
        withDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.offlineStorageLimitGB = 45
            first.automaticOfflineCacheEnabled = true

            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.offlineStorageLimitGB, 45)
            XCTAssertEqual(
                restored.offlineStorageLimitBytes,
                45_000_000_000
            )
            XCTAssertTrue(restored.automaticOfflineCacheEnabled)
        }
    }

    func testOfflineLimitIsClampedAndRoundedToFiveGigabytes() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)

            settings.offlineStorageLimitGB = 2
            XCTAssertEqual(settings.offlineStorageLimitGB, 5)

            settings.offlineStorageLimitGB = 53
            XCTAssertEqual(settings.offlineStorageLimitGB, 55)

            settings.offlineStorageLimitGB = 102
            XCTAssertEqual(settings.offlineStorageLimitGB, 100)
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suite = "AppSettingsOfflineTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
