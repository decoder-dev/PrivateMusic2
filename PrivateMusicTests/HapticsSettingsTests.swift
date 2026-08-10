import XCTest
@testable import PrivateMusic

@MainActor
final class HapticsSettingsTests: XCTestCase {
    func testHapticsDefaultToEnabled() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.hapticsEnabled)
            XCTAssertTrue(Haptics.isEnabled)
        }
    }

    func testHapticsPreferencePersistsAndGatesTheSharedFlag() {
        withDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.hapticsEnabled = false
            XCTAssertFalse(Haptics.isEnabled)

            let restored = AppSettings(defaults: defaults)
            XCTAssertFalse(restored.hapticsEnabled)
            XCTAssertFalse(Haptics.isEnabled)

            restored.hapticsEnabled = true
            XCTAssertTrue(Haptics.isEnabled)
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suite = "HapticsSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
