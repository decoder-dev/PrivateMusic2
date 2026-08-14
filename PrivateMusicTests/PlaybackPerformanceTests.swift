import Combine
import XCTest
@testable import PrivateMusic

@MainActor
final class PlaybackProgressModelTests: XCTestCase {
    func testUpdatesIgnoreSubThresholdDeltas() {
        let progress = PlaybackProgressModel()
        progress.update(1.0, force: true)
        progress.update(1.1)
        XCTAssertEqual(progress.elapsedTime, 1.0, accuracy: 0.000_1)
        progress.update(1.3)
        XCTAssertEqual(progress.elapsedTime, 1.3, accuracy: 0.000_1)
    }

    func testForceResetPublishesImmediately() {
        let progress = PlaybackProgressModel()
        progress.update(12, force: true)
        progress.reset(to: 0)
        XCTAssertEqual(progress.elapsedTime, 0, accuracy: 0.000_1)
    }
}

@MainActor
final class PlaybackHighlightModelTests: XCTestCase {
    func testUpdateStoresIdentityAndPlayState() {
        let highlight = PlaybackHighlightModel()
        XCTAssertNil(highlight.currentTrackID)
        XCTAssertFalse(highlight.isPlaying)
        XCTAssertNil(highlight.queueSource)

        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .album(title: "Album")
        )
        XCTAssertEqual(highlight.currentTrackID, "42")
        XCTAssertTrue(highlight.isPlaying)
        XCTAssertEqual(highlight.queueSource, .album(title: "Album"))
        XCTAssertTrue(highlight.isCurrent("42"))
        XCTAssertFalse(highlight.isCurrent("7"))
    }

    func testRepeatedUpdateDoesNotPublish() {
        let highlight = PlaybackHighlightModel()
        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .album(title: "Album")
        )

        var changes = 0
        let token = highlight.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .album(title: "Album")
        )
        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .album(title: "Album")
        )
        XCTAssertEqual(changes, 0)
    }

    func testChangedValuePublishes() {
        let highlight = PlaybackHighlightModel()
        highlight.update(currentTrackID: "42", isPlaying: true)

        var changes = 0
        let token = highlight.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        // Only the play state moved: identity must not publish again.
        highlight.update(currentTrackID: "42", isPlaying: false)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(highlight.isPlaying)

        highlight.update(currentTrackID: nil, isPlaying: false)
        XCTAssertEqual(changes, 2)
        XCTAssertNil(highlight.currentTrackID)
    }

    func testSourceChangePublishes() {
        let highlight = PlaybackHighlightModel()
        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .album(title: "Album")
        )

        var changes = 0
        let token = highlight.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        highlight.update(
            currentTrackID: "42",
            isPlaying: true,
            queueSource: .playlist(title: "Playlist")
        )

        XCTAssertEqual(changes, 1)
        XCTAssertEqual(highlight.queueSource, .playlist(title: "Playlist"))
    }
}

final class QueueSourcePlaybackActionTests: XCTestCase {
    func testActivePlayingSourcePauses() {
        XCTAssertEqual(
            QueueSourcePlaybackAction.resolve(
                target: .album(title: "Album"),
                isPlaying: true,
                queueSource: .album(title: "Album")
            ),
            .pause
        )
    }

    func testActivePausedSourceResumesWithPlayPresentation() {
        let action = QueueSourcePlaybackAction.resolve(
            target: .album(title: "Album"),
            isPlaying: false,
            queueSource: .album(title: "Album")
        )

        XCTAssertEqual(action, .resume)
        XCTAssertEqual(action.systemImage, "play.fill")
        XCTAssertEqual(action.labelKey, "play")
    }

    func testDifferentSourceStartsNewQueue() {
        XCTAssertEqual(
            QueueSourcePlaybackAction.resolve(
                target: .album(title: "Album"),
                isPlaying: true,
                queueSource: .album(title: "Other")
            ),
            .start
        )
    }

    func testPauseUsesLocalizedAccessibilityKey() {
        XCTAssertEqual(
            QueueSourcePlaybackAction.pause.accessibilityLabelKey(
                playKey: "play_album"
            ),
            "pause"
        )
    }
}

@MainActor
final class PlayerHighlightSyncTests: XCTestCase {
    func testPlayerMirrorsQueueChangesIntoHighlight() {
        let suite = "PlayerHighlightSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(
            settings: AppSettings(defaults: defaults),
            historyStore: ListeningHistoryStore(defaults: defaults),
            defaults: defaults
        )
        let first = track(id: 1)
        let second = track(id: 2)
        XCTAssertNil(player.highlight.currentTrackID)

        player.play(
            first,
            in: [first, second],
            source: .album(title: "Album")
        )
        XCTAssertEqual(player.highlight.currentTrackID, first.id)
        XCTAssertEqual(player.highlight.queueSource, .album(title: "Album"))

        player.next()
        XCTAssertEqual(player.highlight.currentTrackID, second.id)

        player.stop()
        XCTAssertNil(player.highlight.currentTrackID)
        XCTAssertFalse(player.highlight.isPlaying)
        XCTAssertNil(player.highlight.queueSource)
    }

    private func track(id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: "Track \(id)",
            artist: "Artist",
            duration: 180,
            streamURL: URL(string: "https://example.com/\(id).mp3"),
            artworkURL: nil
        )
    }
}

final class RemoteCommandCoalescingTests: XCTestCase {
    func testPauseThenToggleStaysPaused() {
        let merged = RemoteCommandCoalescing.merge(
            pending: .pause,
            incoming: .toggle
        )
        XCTAssertEqual(merged, .pause)
    }

    func testPlayThenToggleStaysPlaying() {
        let merged = RemoteCommandCoalescing.merge(
            pending: .play,
            incoming: .toggle
        )
        XCTAssertEqual(merged, .play)
    }

    func testPlayThenPauseKeepsLatest() {
        XCTAssertEqual(
            RemoteCommandCoalescing.merge(pending: .play, incoming: .pause),
            .pause
        )
    }

    func testSeekYieldsToTransport() {
        XCTAssertEqual(
            RemoteCommandCoalescing.merge(
                pending: .seek(12),
                incoming: .play
            ),
            .play
        )
    }
}

final class PlaybackArtworkPerformancePolicyTests: XCTestCase {
    func testPlayerBackgroundUsesSmallBlurSource() {
        XCTAssertLessThanOrEqual(
            PlayerArtworkBackgroundPolicy.maxPixelSize,
            320
        )
        XCTAssertLessThanOrEqual(
            PlayerArtworkBackgroundPolicy.blurRadius,
            48
        )
    }

    func testNowPlayingArtworkIsBoundedForLockScreen() {
        XCTAssertEqual(NowPlayingArtworkPolicy.maxPixelSize, 600)
    }

    func testCatalogTilesDecodeNearRenderedPixels() {
        XCTAssertEqual(
            ArtworkDecodePolicy.maxPixelSize(displayPoints: 48, scale: 3),
            144
        )
        XCTAssertEqual(
            ArtworkDecodePolicy.maxPixelSize(
                width: 142,
                height: 142,
                scale: 2
            ),
            284
        )
        XCTAssertEqual(
            ArtworkDecodePolicy.maxPixelSize(displayPoints: 40, scale: 2),
            ArtworkDecodePolicy.minimumPixelSize
        )
    }
}

final class NowPlayingDriftPolicyTests: XCTestCase {
    func testForcedPublishAlwaysWins() {
        XCTAssertTrue(
            NowPlayingDriftPolicy.shouldPublish(
                elapsedSeconds: 7,
                lastPublishedSecond: 7,
                force: true
            )
        )
    }

    func testOrdinarySecondsDoNotRepublish() {
        XCTAssertFalse(
            NowPlayingDriftPolicy.shouldPublish(
                elapsedSeconds: 17,
                lastPublishedSecond: 0,
                force: false
            )
        )
    }

    func testDriftBoundaryPublishesOnce() {
        XCTAssertTrue(
            NowPlayingDriftPolicy.shouldPublish(
                elapsedSeconds: 30,
                lastPublishedSecond: 0,
                force: false
            )
        )
        XCTAssertFalse(
            NowPlayingDriftPolicy.shouldPublish(
                elapsedSeconds: 30,
                lastPublishedSecond: 30,
                force: false
            )
        )
    }
}

final class PlaybackSeekTolerancePolicyTests: XCTestCase {
    func testOfflineSeeksStayExact() {
        XCTAssertEqual(
            PlaybackSeekTolerancePolicy.tolerance(isOffline: true),
            .zero
        )
    }

    func testRemoteSeeksAllowSmallTolerance() {
        let tolerance = PlaybackSeekTolerancePolicy.tolerance(isOffline: false)
        XCTAssertEqual(
            tolerance.seconds,
            PlaybackSeekTolerancePolicy.remoteToleranceSeconds,
            accuracy: 0.000_1
        )
    }
}

final class WatchStatePushCoalescingPolicyTests: XCTestCase {
    func testDriftCorrectionIsMuchSlowerThanOneHertz() {
        XCTAssertGreaterThanOrEqual(
            WatchStatePushCoalescingPolicy.driftCorrectionSeconds,
            15
        )
    }

    func testElapsedWithinBucketDoesNotBreakEquality() {
        let early = WatchRemoteState(
            trackID: "1",
            title: "A",
            artist: "B",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 1,
            duration: 180
        )
        let later = WatchRemoteState(
            trackID: "1",
            title: "A",
            artist: "B",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 19,
            duration: 180
        )
        XCTAssertEqual(early, later)

        let nextBucket = WatchRemoteState(
            trackID: "1",
            title: "A",
            artist: "B",
            artworkURL: nil,
            isPlaying: true,
            isBuffering: false,
            elapsed: 21,
            duration: 180
        )
        XCTAssertNotEqual(early, nextBucket)
    }

    func testRegularBurstRemainsNonForced() {
        XCTAssertFalse(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: false,
                incoming: false
            )
        )
    }

    func testForceRemainsStickyAcrossBurst() {
        XCTAssertTrue(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: true,
                incoming: false
            )
        )
        XCTAssertTrue(
            WatchStatePushCoalescingPolicy.mergedForce(
                pending: false,
                incoming: true
            )
        )
    }
}
