import XCTest
@testable import PrivateMusic

final class AppearanceRegressionTests: XCTestCase {
    func testWhiteCaptionsReadOnSaturatedArtwork() {
        for red in stride(from: 0.0, through: 1.0, by: 0.2) {
            for green in stride(from: 0.0, through: 1.0, by: 0.2) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.2) {
                    let fill = BubbleColorComponents(red: red, green: green, blue: blue)
                        .constrainedForSurface()
                    XCTAssertGreaterThanOrEqual(
                        ContrastRatio.between(fill.relativeLuminance, 1), 4.5
                    )
                }
            }
        }
    }

    func testRailCaptionContrastIncludesEveryFallbackRole() {
        for role in BubbleRole.allCases {
            let fill = BubblePalette.surface(role, tint: nil)
                .ensuringContrast(against: [1], towardWhite: false)
            XCTAssertGreaterThanOrEqual(
                ContrastRatio.between(fill.relativeLuminance, 1), 4.5, "\(role)"
            )
        }
    }
}

@MainActor
final class AudioSettingsValidationTests: XCTestCase {
    func testInvalidAudioPreferencesCannotReachTheDSPOrSliders() {
        let suite = "AudioSettingsValidationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Array(repeating: 90.0, count: 10), forKey: "audio.equalizer.gains")
        defaults.set(50.0, forKey: "audio.equalizer.preamp")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.equalizerGains, Array(repeating: 12, count: 10))
        XCTAssertEqual(settings.equalizerPreamp, 6)
        settings.equalizerGains = [1, 2]
        XCTAssertEqual(settings.equalizerGains, EqualizerPreset.flat.gains)
        settings.setGain(.nan, at: 0)
        settings.equalizerPreamp = .infinity
        settings.appVolume = .nan
        settings.spatialAudioIntensity = -.infinity
        XCTAssertEqual(settings.equalizerGains[0], 0)
        XCTAssertEqual(settings.equalizerPreamp, 0)
        XCTAssertEqual(settings.appVolume, 1)
        XCTAssertEqual(settings.spatialAudioIntensity, SpatialAudioDSP.defaultIntensity)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.appVolume, 1)
        XCTAssertEqual(restored.equalizerGains, EqualizerPreset.flat.gains)
    }
}
