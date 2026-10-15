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
            XCTAssertEqual(settings.accent, settings.accentComponents.color)
            XCTAssertEqual(
                settings.onAccent,
                settings.accentComponents.prefersDarkForeground ? .black : .white
            )
            for theme in AppTheme.allCases {
                XCTAssertEqual(
                    AppAccent.blue.components(for: theme),
                    BubbleGamut.accent(for: theme)
                )
            }
        }
    }

    /// The accent is cached (it is read hundreds of times per frame), so the
    /// cache has to follow every input it depends on.
    func testCachedDerivedColoursFollowThemePaletteAndAccent() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            // A closure, not a local func: a local func does not inherit the
            // main actor, and the settings are main-actor state.
            let expected: () -> BubbleColorComponents = {
                settings.accentChoice.components(
                    for: settings.theme,
                    on: settings.palette
                )
            }
            XCTAssertEqual(settings.accentComponents, expected())
            settings.palette = .banana
            settings.accentChoice = .banana
            XCTAssertEqual(settings.accentComponents, expected())
            XCTAssertEqual(
                settings.pageColors.count,
                settings.palette.background(for: settings.theme).count
            )
            settings.theme = .light
            XCTAssertEqual(settings.accentComponents, expected())
            XCTAssertEqual(
                settings.onAccent,
                expected().prefersDarkForeground ? .black : .white
            )
            settings.resetAppearance()
            XCTAssertEqual(settings.accentComponents, expected())
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

    func testSelectingHalloweenActivatesDarkAppearanceAndItsAccent() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .light
            settings.synchronizeAppearance(with: .light)
            settings.applyPalette(.halloween)
            XCTAssertEqual(settings.palette, .halloween)
            XCTAssertEqual(settings.appearance, .dark)
            XCTAssertEqual(settings.theme, .dark)
            XCTAssertEqual(settings.accentChoice, .orange)
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.palette, .halloween)
            XCTAssertEqual(restored.appearance, .dark)
            restored.synchronizeAppearance(with: .light)
            XCTAssertEqual(restored.theme, .dark)
        }
    }

    func testHalloweenPaletteAndCustomAccentSurviveRelaunchWithoutForcingAppearance() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .system
            settings.palette = .halloween
            settings.accentChoice = .violet
            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.palette, .halloween)
            XCTAssertEqual(restored.accentChoice, .violet)
            XCTAssertEqual(restored.appearance, .system)
            restored.resetAppearance()
            XCTAssertEqual(restored.palette, .classic)
            XCTAssertEqual(restored.accentChoice, .blue)
        }
    }

    func testSystemAppearanceFollowsChangesAndPersistsItsMode() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .system
            settings.synchronizeAppearance(with: .light)
            XCTAssertEqual(settings.theme, .light)
            XCTAssertEqual(settings.appearance, .system)
            settings.synchronizeAppearance(with: .dark)
            XCTAssertEqual(settings.theme, .dark)
            XCTAssertEqual(AppSettings(defaults: defaults).appearance, .system)
        }
    }

    func testExplicitAppearanceIgnoresSystemChanges() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .light
            settings.synchronizeAppearance(with: .dark)
            XCTAssertEqual(settings.theme, .light)
            settings.appearance = .dark
            settings.synchronizeAppearance(with: .light)
            XCTAssertEqual(settings.theme, .dark)
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
                    4.5,
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

    func testBlueChoosesTheStrongerLabelInEachAppearance() {
        XCTAssertTrue(BubbleGamut.accent(for: .dark).prefersDarkForeground)
        XCTAssertFalse(BubbleGamut.accent(for: .light).prefersDarkForeground)
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

final class AppPaletteTests: XCTestCase {
    func testEveryAccentReadsOnEveryPaletteAndAppearance() {
        for palette in AppPalette.allCases {
            for theme in AppTheme.allCases {
                for accent in AppAccent.allCases {
                    let color = accent.components(for: theme, on: palette)
                    XCTAssertGreaterThanOrEqual(
                        ContrastRatio.between(
                            color.relativeLuminance,
                            color.prefersDarkForeground ? 0 : 1
                        ),
                        4.5,
                        "button label for \(accent) on \(palette)/\(theme)"
                    )
                    for background in palette.luminances(for: theme) {
                        XCTAssertGreaterThanOrEqual(
                            ContrastRatio.between(
                                color.relativeLuminance,
                                background
                            ),
                            4.5,
                            "\(accent) on \(palette)/\(theme)"
                        )
                    }
                }
            }
        }
    }

    /// The original look stays: on the classic page an accent moves only if
    /// it was short of 4.5:1, and then by a hair.
    func testClassicPaletteBarelyMovesTheOriginalAccents() {
        for theme in AppTheme.allCases {
            for accent in AppAccent.allCases {
                let original = accent.components(for: theme)
                let adjusted = accent.components(for: theme, on: .classic)
                XCTAssertLessThanOrEqual(abs(adjusted.red - original.red), 0.03, "\(accent)")
                XCTAssertLessThanOrEqual(abs(adjusted.green - original.green), 0.03, "\(accent)")
                XCTAssertLessThanOrEqual(abs(adjusted.blue - original.blue), 0.03, "\(accent)")
            }
        }
    }

    func testBananaPaletteUsesTheBananaGramColors() {
        let dark = AppPalette.banana.background(for: .dark)[0]
        XCTAssertEqual(dark.red, Double(0x18) / 255, accuracy: 0.001)
        XCTAssertEqual(dark.green, Double(0x1B) / 255, accuracy: 0.001)
        XCTAssertEqual(dark.blue, Double(0x20) / 255, accuracy: 0.001)
        let cream = AppPalette.banana.surface(for: .light)
        XCTAssertEqual(cream.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(cream.blue, Double(0xF5) / 255, accuracy: 0.001)
        XCTAssertEqual(AppPalette.banana.accent, .banana)
    }

    func testPalettesAreDistinctAndLabelsReadOnTheirAccent() {
        XCTAssertEqual(
            Set(AppPalette.allCases.map(\.rawValue)).count,
            AppPalette.allCases.count
        )
        for palette in AppPalette.allCases {
            for theme in AppTheme.allCases {
                let fill = palette.accent.components(for: theme, on: palette)
                let label = fill.prefersDarkForeground ? 0.0 : 1.0
                XCTAssertGreaterThanOrEqual(
                    ContrastRatio.between(fill.relativeLuminance, label),
                    4.5,
                    "\(palette)/\(theme)"
                )
            }
        }
    }
}
