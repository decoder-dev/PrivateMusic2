import XCTest
@testable import PrivateMusic

@MainActor
final class PlayerPersistenceTests: XCTestCase {
    func testMinimumVolumePauseIsOptIn() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppSettings(defaults: defaults).pauseAtMinimumVolume)
    }

    func testAppVolumeDefaultsToFullAndPersistsClampedValue() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        XCTAssertEqual(first.appVolume, 1)
        first.appVolume = 1.5
        XCTAssertEqual(first.appVolume, 1)
        first.appVolume = 0.35

        XCTAssertEqual(
            AppSettings(defaults: defaults).appVolume,
            0.35,
            accuracy: 0.001
        )
    }

    func testPlaybackErrorPolicyPersistsAcrossSettingsInstances() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        XCTAssertTrue(first.advanceOnPlaybackError)
        first.advanceOnPlaybackError = false

        let restored = AppSettings(defaults: defaults)
        XCTAssertFalse(restored.advanceOnPlaybackError)
    }

    func testEqualizerSettingsPersistWithoutLosingCustomBandValues() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.equalizerEnabled = true
        first.equalizerPreamp = -2.5
        first.setGain(5.5, at: 3)

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.equalizerEnabled)
        XCTAssertEqual(restored.equalizerPreamp, -2.5)
        XCTAssertEqual(restored.equalizerPreset, .custom)
        XCTAssertEqual(restored.equalizerGains[3], 5.5)
    }

    func testSpatialAudioSettingsPersistAndClampIntensity() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.spatialAudioEnabled)
        XCTAssertEqual(
            first.spatialAudioIntensity,
            SpatialAudioDSP.defaultIntensity
        )

        first.spatialAudioEnabled = true
        first.spatialAudioIntensity = 2

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.spatialAudioEnabled)
        XCTAssertEqual(restored.spatialAudioIntensity, 1)
    }

    func testCrossfadeDefaultsOnAndPersists() {
        let suite = "PlayerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        XCTAssertTrue(first.crossfadeEnabled)
        first.crossfadeEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).crossfadeEnabled)
    }

    func testRemovingStoredTrackClearsSourceAndStoredAliases() {
        let store = MusicLibraryStore()
        let source = track(
            id: 1,
            ownerID: 20,
            title: "Same Song"
        )
        let stored = track(
            id: 99,
            ownerID: 42,
            title: "Same Song"
        )

        store.markAdded(source: source, stored: stored)
        XCTAssertTrue(store.contains(source))
        XCTAssertTrue(store.contains(stored))

        store.markRemoved(stored)

        XCTAssertFalse(store.contains(source))
        XCTAssertFalse(store.contains(stored))
        XCTAssertNil(store.storedTrack(for: source))
    }

    private func track(
        id: Int,
        ownerID: Int,
        title: String
    ) -> Track {
        Track(
            trackID: id,
            ownerID: ownerID,
            title: title,
            artist: "Artist",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
