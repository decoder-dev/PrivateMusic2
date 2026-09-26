import XCTest
@testable import PrivateMusic

final class QueueEditingPolicyTests: XCTestCase {
    func testMoveKeepsPlayedAndCurrentTracksInPlace() {
        XCTAssertEqual(
            PlaybackQueueEditing.movingUpcoming(
                in: [1, 2, 3, 4, 5], currentIndex: 1, from: IndexSet(integer: 2), to: 0
            ),
            [1, 2, 5, 3, 4]
        )
    }

    func testMoveDownUsesListDestinationSemantics() {
        XCTAssertEqual(
            PlaybackQueueEditing.movingUpcoming(
                in: [1, 2, 3, 4], currentIndex: 0, from: IndexSet(integer: 0), to: 3
            ),
            [1, 3, 4, 2]
        )
    }

    func testMultipleRowsKeepTheirRelativeOrder() {
        XCTAssertEqual(
            PlaybackQueueEditing.movingUpcoming(
                in: [1, 2, 3, 4, 5], currentIndex: 0, from: IndexSet([0, 2]), to: 4
            ),
            [1, 3, 5, 2, 4]
        )
    }

    func testStaleOrInvalidOffsetsLeaveQueueIntact() {
        for currentIndex: Int? in [nil, -1, 99] {
            XCTAssertEqual(
                PlaybackQueueEditing.movingUpcoming(
                    in: [1, 2], currentIndex: currentIndex, from: IndexSet(integer: 0), to: 1
                ), [1, 2]
            )
        }
        XCTAssertEqual(
            PlaybackQueueEditing.movingUpcoming(
                in: [1, 2], currentIndex: 0, from: IndexSet(integer: 4), to: 0
            ), [1, 2]
        )
    }
}

@MainActor
final class QueueEditingPlayerTests: XCTestCase {
    private func withPlayer(_ test: (AudioPlayer, UserDefaults) -> Void) {
        let suite = "QueueEditingPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let player = AudioPlayer(
            settings: AppSettings(defaults: defaults),
            historyStore: ListeningHistoryStore(defaults: defaults),
            defaults: defaults
        )
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        test(player, defaults)
    }

    private var tracks: [Track] {
        (1...4).map {
            Track(trackID: $0, ownerID: 1, title: "T\($0)", artist: "A",
                  duration: 180, streamURL: nil, artworkURL: nil)
        }
    }

    func testReorderingDoesNotChangeThePlayingTrack() {
        withPlayer { player, _ in
            player.play(tracks[0], in: tracks, source: .library)
            player.moveUpcoming(from: IndexSet(integer: 2), to: 0, after: tracks[0].id)
            XCTAssertEqual(player.currentTrack?.id, tracks[0].id)
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertEqual(player.queue.map(\.trackID), [1, 4, 2, 3])
        }
    }

    func testMoveFromPreviousTrackCannotEditTheNewTracksQueue() {
        withPlayer { player, _ in
            player.play(tracks[1], in: tracks, source: .library)
            player.moveUpcoming(from: IndexSet(integer: 1), to: 0, after: tracks[0].id)
            XCTAssertEqual(player.queue.map(\.trackID), [1, 2, 3, 4])
        }
    }

    func testClearKeepsCurrentTrackAndStopsAutoAddUntilNewQueue() {
        withPlayer { player, defaults in
            player.configureContinuation { [] }
            player.play(tracks[1], in: tracks, source: .library)
            player.clearUpcoming()
            XCTAssertEqual(player.queue.map(\.trackID), [1, 2])
            XCTAssertEqual(player.currentTrack?.id, tracks[1].id)
            XCTAssertTrue(defaults.bool(forKey: "player.continuationSuppressed"))
            XCTAssertFalse(player.hasAutomaticContinuation)
            player.play(tracks[0], in: tracks, source: .library)
            XCTAssertFalse(defaults.bool(forKey: "player.continuationSuppressed"))
            XCTAssertTrue(player.hasAutomaticContinuation)
        }
    }

    func testFilteredPlaybackCannotFallBackToDefaultRecommendations() {
        withPlayer { player, _ in
            player.configureContinuation { [self.tracks[3]] }
            player.play(tracks[0], in: tracks, source: .library, allowsContinuation: false)
            XCTAssertFalse(player.hasAutomaticContinuation)
            player.playShuffled(in: tracks, source: .library, allowsContinuation: false)
            XCTAssertFalse(player.hasAutomaticContinuation)
        }
    }

    func testClearedQueueDoesNotResumeAutoAddAfterRelaunch() {
        withPlayer { player, defaults in
            player.configureContinuation { [] }
            player.play(tracks[0], in: tracks, source: .library)
            player.clearUpcoming()
            let restored = AudioPlayer(
                settings: AppSettings(defaults: defaults),
                historyStore: ListeningHistoryStore(defaults: defaults),
                defaults: defaults
            )
            defer { restored.stop() }
            restored.configureContinuation { [] }
            XCTAssertFalse(restored.hasAutomaticContinuation)
            XCTAssertEqual(restored.currentTrack?.id, tracks[0].id)
        }
    }
}
