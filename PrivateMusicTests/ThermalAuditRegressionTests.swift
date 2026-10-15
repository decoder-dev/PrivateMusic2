import AVFoundation
import Observation
import XCTest
@testable import PrivateMusic

@MainActor
final class ThermalAuditRegressionTests: XCTestCase {
    func testOptionalArtworkWorkYieldsToLowPowerAndThermalPressure() {
        XCTAssertTrue(DecorativeWorkPolicy.allowsSpeculativeWork(lowPowerMode: false, thermalState: .nominal))
        XCTAssertTrue(DecorativeWorkPolicy.allowsSpeculativeWork(lowPowerMode: false, thermalState: .fair))
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            XCTAssertFalse(DecorativeWorkPolicy.allowsSpeculativeWork(lowPowerMode: true, thermalState: thermal))
        }
        XCTAssertFalse(DecorativeWorkPolicy.allowsSpeculativeWork(lowPowerMode: false, thermalState: .serious))
        XCTAssertFalse(DecorativeWorkPolicy.allowsSpeculativeWork(lowPowerMode: false, thermalState: .critical))
    }

    func testObservationSideEffectsDoNotSubscribeToUnrelatedStoreChanges() async {
        let state = AuditObservationState()
        var calls = 0
        let token = ObservationLoop.start(observing: { _ = state.input }, apply: {
            _ = state.unrelated
            calls += 1
        })
        defer { token.isCancelled = true }
        XCTAssertEqual(calls, 1)
        state.unrelated += 1
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        state.input += 1
        for _ in 0..<100 where calls == 1 { await Task.yield() }
        XCTAssertEqual(calls, 2)
        token.isCancelled = true
        state.input += 1
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 2)
    }

    func testSavedLyricSearchCacheInvalidatesForSaveAndAccountSwitch() {
        let suite = "ThermalLyrics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedLyricsStore(defaults: defaults)
        let track = Track(trackID: 1, ownerID: 2, title: "Вечер", artist: "ATL", duration: 120,
                          streamURL: nil, artworkURL: nil)
        store.configure(accountID: 1)
        store.save(Lyrics(text: "Тёплый свет", source: "test"), for: track)
        XCTAssertEqual(store.search("ATL теплый").map(\.id), [track.id])
        XCTAssertEqual(store.search("ATL теплый").map(\.id), [track.id])
        store.save(Lyrics(text: "Холодный ветер", source: "test"), for: track)
        XCTAssertTrue(store.search("ATL теплый").isEmpty)
        XCTAssertEqual(store.search("вечер холодный").map(\.id), [track.id])
        store.configure(accountID: 2)
        XCTAssertTrue(store.search("вечер холодный").isEmpty)
        store.configure(accountID: 1)
        XCTAssertEqual(store.search("вечер холодный").map(\.id), [track.id])
    }

    func testQueueTailAppendPreservesWarmNeighborButReplacementInvalidatesIt() {
        func track(_ id: Int, url: String? = nil) -> Track {
            Track(trackID: id, ownerID: 1, title: "T", artist: "A", duration: 120,
                  streamURL: URL(string: url ?? "https://example.com/\(id).mp3"), artworkURL: nil)
        }
        let queue = [track(1), track(2)]
        XCTAssertFalse(PlaybackPreloadPolicy.shouldInvalidateNeighbor(oldQueue: queue,
            newQueue: queue + [track(3)], currentIndex: 0, repeatMode: .off))
        XCTAssertTrue(PlaybackPreloadPolicy.shouldInvalidateNeighbor(oldQueue: queue,
            newQueue: [track(1), track(3)], currentIndex: 0, repeatMode: .off))
        XCTAssertTrue(PlaybackPreloadPolicy.shouldInvalidateNeighbor(oldQueue: queue,
            newQueue: [track(1), track(2, url: "https://example.com/new.mp3")], currentIndex: 0, repeatMode: .off))
        XCTAssertTrue(PlaybackPreloadPolicy.shouldInvalidateNeighbor(oldQueue: queue,
            newQueue: queue + [track(3)], currentIndex: 1, repeatMode: .all))
    }

    func testThermalAndPowerNotificationsDoNotReplaceUnprocessedPlaybackItem() async throws {
        let suite = "ThermalPlayer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).caf")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer)
        file = nil
        let settings = AppSettings(defaults: defaults)
        settings.equalizerEnabled = false
        settings.loudnessNormalization = false
        settings.dynamicRangeCompression = false
        settings.spatialAudioEnabled = false
        settings.crossfadeEnabled = false
        let player = AudioPlayer(settings: settings, historyStore: ListeningHistoryStore(defaults: defaults), defaults: defaults)
        defer { player.stop() }
        player.configureOfflinePlayback(lookup: { _ in url }, invalidate: { _ in }, markPlayed: { _ in })
        let track = Track(trackID: 3, ownerID: 2, title: "Fixture", artist: "Audit", duration: 2,
                          streamURL: url, artworkURL: nil)
        player.play(track, in: [track])
        for _ in 0..<200 where player.currentPlaybackItemForDiagnostics == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try XCTUnwrap(player.currentPlaybackItemForDiagnostics)
        player.pause()
        // Allow the initial debounced settings application to settle.
        try await Task.sleep(for: .milliseconds(150))
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(player.currentPlaybackItemForDiagnostics === original)
        XCTAssertEqual(player.currentTrack?.id, track.id)
    }
}

@MainActor
@Observable
private final class AuditObservationState {
    var input = 0
    var unrelated = 0
}
