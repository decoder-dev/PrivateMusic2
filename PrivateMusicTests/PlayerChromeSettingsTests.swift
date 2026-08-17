import XCTest
@testable import PrivateMusic

@MainActor
final class PlayerChromeSettingsTests: XCTestCase {
    func testPlayerKeepsLiquidGlassByDefault() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertFalse(settings.classicChrome)
        }
    }

    /// 3.28.82 stored the switch under a player-only key before it grew to
    /// cover the tab chrome. Anyone who flipped it there keeps their choice.
    func testClassicChromeMigratesFromThePlayerOnlyKey() {
        withDefaults { defaults in
            defaults.set(true, forKey: "appearance.player.classic")

            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.classicChrome)
        }
    }

    func testClassicChromeSurvivesRelaunch() {
        withDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.classicChrome = true

            let restored = AppSettings(defaults: defaults)
            XCTAssertTrue(restored.classicChrome)
        }
    }

    /// «Сбросить оформление» is the escape hatch for a player somebody has
    /// made unreadable, so it has to reach this switch as well.
    func testResetAppearanceRestoresLiquidGlass() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.classicChrome = true
            settings.resetAppearance()

            XCTAssertFalse(settings.classicChrome)
            XCTAssertFalse(
                AppSettings(defaults: defaults).classicChrome
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
