import XCTest
@testable import PrivateMusic

@MainActor
final class AppearanceChoiceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testDefaultAccentIsTheOriginalBlue() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.accentChoice, .blue)
            for theme in AppTheme.allCases {
                XCTAssertEqual(
                    AppAccent.blue.components(for: theme),
                    BubbleGamut.accent(for: theme)
                )
            }
        }
    }

    func testAccentChoicePersistsAndUnknownValuesFallBackToBlue() {
        withDefaults { defaults in
            AppSettings(defaults: defaults).accentChoice = .violet
            XCTAssertEqual(AppSettings(defaults: defaults).accentChoice, .violet)
            defaults.set("not-an-accent", forKey: "appearance.accent")
            XCTAssertEqual(AppSettings(defaults: defaults).accentChoice, .blue)
        }
    }

    func testEveryAccentHasADistinctColourPerTheme() {
        for theme in AppTheme.allCases {
            let all = AppAccent.allCases.map { $0.components(for: theme) }
            XCTAssertEqual(Set(all).count, all.count, "duplicate accent on \(theme)")
        }
        for accent in AppAccent.allCases {
            XCTAssertNotEqual(
                accent.components(for: .dark),
                accent.components(for: .light),
                "\(accent) must adapt to the surface"
            )
        }
    }
}

final class EqualizerPresetCatalogTests: XCTestCase {
    func testEveryPresetCoversTenBandsInsideTheSliderRange() {
        for preset in EqualizerPreset.allCases {
            XCTAssertEqual(preset.gains.count, 10, "\(preset)")
            XCTAssertTrue(preset.gains.allSatisfy { abs($0) <= 12 }, "\(preset)")
        }
    }

    func testPresetIdentifiersAreUniqueAndFlatIsNeutral() {
        let ids = EqualizerPreset.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(EqualizerPreset.flat.gains.allSatisfy { $0 == 0 })
    }

    func testOriginalPresetsKeepTheirStoredIdentifiers() {
        for raw in ["flat", "bass", "vocal", "electronic", "rock", "custom"] {
            XCTAssertNotNil(EqualizerPreset(rawValue: raw), raw)
        }
    }

    func testNoTwoPresetsShareTheSameCurve() {
        let named = EqualizerPreset.allCases.filter { $0 != .custom }
        let curves = Set(named.map { $0.gains.map { String($0) }.joined(separator: ",") })
        XCTAssertEqual(curves.count, named.count)
    }
}
