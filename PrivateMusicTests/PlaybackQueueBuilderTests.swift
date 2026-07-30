import XCTest
@testable import PrivateMusic

final class PlaybackQueueBuilderTests: XCTestCase {
    func testSelectedTrackIsInsertedWhenMissing() {
        let selected = track(id: 7, title: "Selected")
        let result = PlaybackQueueBuilder.normalized(
            selected: selected,
            tracks: [track(id: 1), track(id: 2)]
        )

        XCTAssertEqual(result.map(\.id), [
            selected.id,
            "10_1",
            "10_2"
        ])
    }

    func testDuplicateIdentifiersAreRemovedAndSelectedValueWins() {
        let stale = track(id: 3, title: "Old")
        let selected = track(id: 3, title: "Fresh")
        let result = PlaybackQueueBuilder.normalized(
            selected: selected,
            tracks: [stale, stale, track(id: 4)]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.title, "Fresh")
    }

    private func track(
        id: Int,
        title: String = "Track"
    ) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: title,
            artist: "Artist",
            duration: 180,
            streamURL: URL(string: "https://example.com/\(id).mp3"),
            artworkURL: nil
        )
    }
}

@MainActor
final class AudioPlayerTransitionTests: XCTestCase {
    func testChangingTrackResetsElapsedTimeAndDurationImmediately() {
        let suite = "AudioPlayerTransitionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let history = ListeningHistoryStore(defaults: defaults)
        let player = AudioPlayer(
            settings: settings,
            historyStore: history,
            defaults: defaults
        )
        let first = track(id: 1, duration: 180)
        let second = track(id: 2, duration: 245)

        player.play(first, in: [first, second])
        player.seek(to: 73)
        XCTAssertEqual(player.elapsedTime, 73)

        player.next()

        XCTAssertEqual(player.currentTrack?.id, second.id)
        XCTAssertEqual(player.elapsedTime, 0)
        XCTAssertEqual(player.duration, second.duration)
    }

    private func track(
        id: Int,
        duration: TimeInterval
    ) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: "Track \(id)",
            artist: "Artist",
            duration: duration,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
