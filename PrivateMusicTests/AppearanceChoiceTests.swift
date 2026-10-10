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

final class AccentContrastTests: XCTestCase {
    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testEveryAccentKeepsReadableLabelsOnBothSurfaces() {
        for accent in AppAccent.allCases {
            for theme in AppTheme.allCases {
                let fill = accent.components(for: theme)
                let label = fill.prefersDarkForeground ? 0.0 : 1.0
                XCTAssertGreaterThanOrEqual(
                    contrast(fill.relativeLuminance, label),
                    3.0,
                    "\(accent) on \(theme)"
                )
            }
        }
    }

    /// Accent-coloured text and glyphs sit directly on the page, so the
    /// accent itself — not only its label — has to read there (WCAG AA).
    func testEveryAccentIsReadableAsTextOnItsOwnBackground() {
        let pageDark = BubbleColorComponents(red: 0.055, green: 0.055, blue: 0.055)
        let pageLight = BubbleColorComponents(red: 0.965, green: 0.965, blue: 0.965)
        for accent in AppAccent.allCases {
            XCTAssertGreaterThanOrEqual(
                contrast(
                    accent.components(for: .dark).relativeLuminance,
                    pageDark.relativeLuminance
                ),
                4.5,
                "\(accent) on the dark page"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(
                    accent.components(for: .light).relativeLuminance,
                    pageLight.relativeLuminance
                ),
                4.5,
                "\(accent) on the light page"
            )
        }
    }

    func testTheOriginalBlueKeepsItsWhiteLabel() {
        for theme in AppTheme.allCases {
            XCTAssertFalse(
                BubbleGamut.accent(for: theme).prefersDarkForeground,
                "\(theme)"
            )
        }
    }

    func testBrightAccentsSwitchToDarkLabels() {
        XCTAssertTrue(
            AppAccent.orange.components(for: .dark).prefersDarkForeground
        )
        XCTAssertTrue(
            AppAccent.green.components(for: .dark).prefersDarkForeground
        )
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
