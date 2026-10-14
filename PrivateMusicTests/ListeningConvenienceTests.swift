import MediaPlayer
import XCTest
@testable import PrivateMusic

@MainActor
final class PinnedCollectionsStoreTests: XCTestCase {
    func testPinsPersistWithoutCrossingAccountsAndKeepStableUnpinnedOrder() {
        let suite = "Pins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinnedCollectionsStore(defaults: defaults)
        store.configure(accountID: 1)
        store.toggle("album:3"); store.toggle("playlist:2")
        XCTAssertEqual(store.ordered(["1", "album:3", "4", "playlist:2"], identity: { $0 }),
                       ["playlist:2", "album:3", "1", "4"])
        store.configure(accountID: 2)
        XCTAssertTrue(store.identities.isEmpty)
        store.toggle("other")
        store.configure(accountID: 1)
        XCTAssertEqual(store.identities, ["playlist:2", "album:3"])
        store.configure(accountID: nil)
        store.toggle("ignored")
        XCTAssertTrue(store.identities.isEmpty)
        let restored = PinnedCollectionsStore(defaults: defaults)
        restored.configure(accountID: 1)
        restored.toggle("playlist:2")
        XCTAssertEqual(restored.identities, ["album:3"])
    }

    func testPinnedMetadataSurvivesOfflineRelaunchAndUnpinClearsIt() {
        let suite = "PinMetadata.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinnedCollectionsStore(defaults: defaults)
        store.configure(accountID: 1)
        let playlist = Playlist(id: 7, ownerID: 2, title: "Дорога", count: 14)
        store.toggle(playlist: playlist)
        let album = Album(id: 8, ownerID: 2, title: "Вечер", count: 9,
                          accessKey: "local-test-key", artists: ["Тест"], releaseYear: 2026, isFollowed: true)
        store.toggle(album: album)
        let restored = PinnedCollectionsStore(defaults: defaults)
        restored.configure(accountID: 1)
        XCTAssertEqual(restored.playlistSnapshots.first?.title, "Дорога")
        XCTAssertEqual(restored.albumSnapshots.first, album)
        XCTAssertEqual(restored.availablePlaylists([]).first?.title, "Дорога")
        let updated = Playlist(id: 7, ownerID: 2, title: "Дорога — обновлено", count: 20)
        XCTAssertEqual(restored.availablePlaylists([updated]).count, 1)
        XCTAssertEqual(restored.availablePlaylists([updated]).first?.title, updated.title)
        XCTAssertEqual(restored.availableAlbums([]).first, album)
        restored.toggle(album: album)
        XCTAssertTrue(restored.albumSnapshots.isEmpty)
        restored.toggle(playlist: playlist)
        XCTAssertTrue(restored.playlistSnapshots.isEmpty)
        XCTAssertTrue(restored.identities.isEmpty)
    }

    func testPinLimitDoesNotSilentlyEvictExistingCollections() {
        let suite = "PinLimit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinnedCollectionsStore(defaults: defaults)
        store.configure(accountID: 1)
        for index in 0..<PinnedCollectionsStore.limit { store.toggle("p\(index)") }
        store.toggle("overflow")
        XCTAssertFalse(store.contains("overflow"))
        XCTAssertTrue(store.contains("p0"))
        XCTAssertEqual(store.identities.count, PinnedCollectionsStore.limit)
    }

    func testPlaylistPinsKeepOwnersAndCollectionKindsDistinct() {
        let a = Playlist(id: 1, ownerID: 1, title: "A", count: 1)
        let b = Playlist(id: 1, ownerID: 2, title: "B", count: 1)
        let album = Album(id: 1, ownerID: 1, title: "A", count: 1, artists: [])
        XCTAssertNotEqual(PinnedCollectionsStore.playlistKey(a), PinnedCollectionsStore.playlistKey(b))
        XCTAssertNotEqual(PinnedCollectionsStore.playlistKey(a), PinnedCollectionsStore.albumKey(album))
    }
}

final class ListeningContextTests: XCTestCase {
    func testServerActivitySettingWinsOverFallbackMood() {
        let tuning = MixTuning(categories: [MixTuningCategory(id: "activity", title: "Activity", allowsMultiple: false,
                          options: [MixTuningOption(id: "road-id", title: "В дороге", isSelected: false)])])
        guard case .tuned(let mix) = ListeningContext.road.selection(tuning: tuning, mixes: []) else {
            return XCTFail("Expected the actual server activity")
        }
        XCTAssertEqual(mix.streamOptions, #"{"activity":["road-id"]}"#)
    }

    func testContextUsesAvailableCatalogMixAndExplicitMoodFallback() {
        let mix = MusicMix(id: "focus", title: "Для работы", subtitle: "")
        guard case .catalog(let selected) = ListeningContext.work.selection(tuning: nil, mixes: [mix]) else {
            return XCTFail("Expected the available catalog mix")
        }
        XCTAssertEqual(selected.id, mix.id)
        guard case .mood(let mood) = ListeningContext.evening.selection(tuning: nil, mixes: []) else {
            return XCTFail("Expected the explicit fallback")
        }
        XCTAssertEqual(mood, .calm)
    }
}

final class NowPlayingTimelinePolicyTests: XCTestCase {
    func testMeasuredDurationWinsAndUnknownDurationRemainsUnknown() {
        XCTAssertEqual(NowPlayingTimelinePolicy.duration(actual: 181, fallback: 220), 181)
        XCTAssertEqual(NowPlayingTimelinePolicy.duration(actual: .nan, fallback: 220), 220)
        XCTAssertNil(NowPlayingTimelinePolicy.duration(actual: .infinity, fallback: .nan))
        XCTAssertEqual(NowPlayingTimelinePolicy.elapsed(500, duration: 181), 181)
        XCTAssertEqual(NowPlayingTimelinePolicy.elapsed(.nan, duration: 181), 0)
    }

    func testSystemClockDoesNotRunDuringBufferingOrPause() {
        XCTAssertEqual(NowPlayingTimelinePolicy.rate(intendsPlayback: true, isAdvancing: false, playerRate: 1), 0)
        XCTAssertEqual(NowPlayingTimelinePolicy.rate(intendsPlayback: false, isAdvancing: true, playerRate: 1), 0)
        XCTAssertEqual(NowPlayingTimelinePolicy.rate(intendsPlayback: true, isAdvancing: true, playerRate: .nan), 0)
        XCTAssertEqual(NowPlayingTimelinePolicy.rate(intendsPlayback: true, isAdvancing: true, playerRate: 1), 1)
    }

    func testCoarseClockCorrectsDriftWithoutHittingAMultipleOfThirty() {
        XCTAssertTrue(NowPlayingDriftPolicy.shouldPublish(elapsedSeconds: 33, lastPublishedSecond: 1, force: false))
        XCTAssertTrue(NowPlayingDriftPolicy.shouldPublish(elapsedSeconds: 8, lastPublishedSecond: 40, force: false))
        XCTAssertFalse(NowPlayingDriftPolicy.shouldPublish(elapsedSeconds: 33, lastPublishedSecond: 32, force: false))
    }

    func testOnlyShortForwardProgressUsesNativeSliderMotion() {
        XCTAssertTrue(PlayerProgressPolicy.shouldAnimateStep(from: 10, to: 10.5, reduceMotion: false))
        XCTAssertFalse(PlayerProgressPolicy.shouldAnimateStep(from: 10, to: 50, reduceMotion: false))
        XCTAssertFalse(PlayerProgressPolicy.shouldAnimateStep(from: 50, to: 10, reduceMotion: false))
        XCTAssertFalse(PlayerProgressPolicy.shouldAnimateStep(from: 10, to: 10.5, reduceMotion: true))
        XCTAssertEqual(PlayerProgressPolicy.sliderRange(duration: .nan), 0...1)
    }
}

@MainActor
final class NowPlayingControllerTimelineTests: XCTestCase {
    func testMeasuredDurationAndBufferingRateReachTheSystemCard() {
        let center = MPNowPlayingInfoCenter.default()
        let oldInfo = center.nowPlayingInfo
        let oldState = center.playbackState
        let controller = NowPlayingController()
        defer { controller.clear(); center.nowPlayingInfo = oldInfo; center.playbackState = oldState }
        let track = Track(trackID: 7, ownerID: 1, title: "Timeline", artist: "Test", duration: 220,
                          streamURL: nil, artworkURL: nil)
        controller.update(track: track, elapsedTime: 47, rate: 1, queueCount: 1, queueIndex: 0, duration: 181)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 181)
        controller.updatePlayback(elapsedTime: 50, rate: 0, duration: 179, intendsPlayback: true)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 179)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 50)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 0)
        controller.updatePlayback(elapsedTime: 300, rate: 0, duration: 179, intendsPlayback: false)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 179)
    }
}
