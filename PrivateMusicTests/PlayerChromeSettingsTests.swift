import XCTest
@testable import PrivateMusic

@MainActor
final class PlayerChromeSettingsTests: XCTestCase {
    func testPlayerKeepsLiquidGlassByDefault() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertFalse(settings.classicPlayerChrome)
        }
    }

    func testClassicChromeSurvivesRelaunch() {
        withDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.classicPlayerChrome = true

            let restored = AppSettings(defaults: defaults)
            XCTAssertTrue(restored.classicPlayerChrome)
        }
    }

    /// «Сбросить оформление» is the escape hatch for a player somebody has
    /// made unreadable, so it has to reach this switch as well.
    func testResetAppearanceRestoresLiquidGlass() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.classicPlayerChrome = true
            settings.resetAppearance()

            XCTAssertFalse(settings.classicPlayerChrome)
            XCTAssertFalse(
                AppSettings(defaults: defaults).classicPlayerChrome
            )
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suite = "PlayerChromeSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
