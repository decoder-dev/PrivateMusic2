import XCTest
@testable import PrivateMusic

/// «Трек 1 из 100» while Медиатека holds 833 tracks: a library queue used to
/// share the mix ceiling (`MixTrackRequestPolicy.queueLimit`, 80), so every
/// library page appended after the loaded window was thrown away.
@MainActor
final class LibraryQueueCapacityTests: XCTestCase {
    func testTheLibraryCeilingIsFarAboveTheMixCeiling() {
        XCTAssertEqual(MixTrackRequestPolicy.queueLimit, 80)
        XCTAssertEqual(LibraryQueuePolicy.queueLimit, 2_000)
        XCTAssertGreaterThan(
            LibraryQueuePolicy.queueLimit,
            MixTrackRequestPolicy.queueLimit
        )
        XCTAssertEqual(
            LibraryQueuePolicy.upcomingLimit(for: .library),
            LibraryQueuePolicy.queueLimit
        )
        for source: QueueSource? in [
            nil,
            .mix(title: "Selena"),
            .playlist(title: "P"),
            .album(title: "A"),
            .history
        ] {
            XCTAssertEqual(
                LibraryQueuePolicy.upcomingLimit(for: source),
                MixTrackRequestPolicy.queueLimit,
                "only Медиатека may leave the mix ceiling"
            )
        }
    }

    func testAppendableCountNeverGoesNegative() {
        XCTAssertEqual(
            LibraryQueuePolicy.appendableCount(
                upcomingCount: 5_000,
                source: .library
            ),
            0
        )
        XCTAssertEqual(
            LibraryQueuePolicy.appendableCount(
                upcomingCount: 99,
                source: .library
            ),
            LibraryQueuePolicy.queueLimit - 99
        )
        XCTAssertEqual(
            LibraryQueuePolicy.appendableCount(
                upcomingCount: 9,
                source: .mix(title: "Selena")
            ),
            MixTrackRequestPolicy.queueLimit - 9
        )
    }

    // The reported defect: a library that pages far past its loaded window
    // must be able to queue past it.
    func testALibraryQueueGrowsPastTheLoadedPage() {
        let context = makePlayer()
        defer { context.tearDown() }
        let loadedPage = tracks(count: 100)

        context.player.play(loadedPage[0], in: loadedPage, source: .library)
        XCTAssertEqual(context.player.queue.count, 100)

        // Seven more `audio.get` pages, the way the library continuation
        // hands them over.
        for page in 1...7 {
            context.player.appendToQueue(
                tracks(count: 100, idOffset: page * 100)
            )
        }

        XCTAssertEqual(context.player.queue.count, 800)
        XCTAssertGreaterThan(context.player.queue.count, 100)
        XCTAssertEqual(upcomingCount(in: context.player), 799)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, loadedPage[0].id)
    }

    func testAMixQueueStillStopsAtTheMixCeiling() {
        let context = makePlayer()
        defer { context.tearDown() }
        let seedPage = tracks(count: 10, idOffset: 5_000)

        context.player.play(
            seedPage[0],
            in: seedPage,
            source: .mix(title: "Selena")
        )

        for page in 1...7 {
            context.player.appendToQueue(
                tracks(count: 100, idOffset: page * 100)
            )
        }

        XCTAssertEqual(
            upcomingCount(in: context.player),
            MixTrackRequestPolicy.queueLimit
        )
        XCTAssertEqual(
            context.player.queue.count,
            MixTrackRequestPolicy.queueLimit + 1
        )
    }

    // Same append, same tracks — only the source of the queue decides how
    // much of it survives.
    func testOnlyTheQueueSourceDecidesTheCeiling() {
        let library = makePlayer()
        defer { library.tearDown() }
        let mix = makePlayer()
        defer { mix.tearDown() }
        let seedPage = tracks(count: 10, idOffset: 5_000)
        let addition = tracks(count: 300, idOffset: 100)

        library.player.play(seedPage[0], in: seedPage, source: .library)
        library.player.appendToQueue(addition)
        mix.player.play(
            seedPage[0],
            in: seedPage,
            source: .mix(title: "Selena")
        )
        mix.player.appendToQueue(addition)

        XCTAssertEqual(library.player.queue.count, 310)
        XCTAssertEqual(
            mix.player.queue.count,
            MixTrackRequestPolicy.queueLimit + 1
        )
    }

    // The ceiling is a real bound, not "no limit at all".
    func testTheLibraryCeilingStillBoundsARunawayContinuation() {
        let context = makePlayer()
        defer { context.tearDown() }
        let loadedPage = tracks(count: 100)

        context.player.play(loadedPage[0], in: loadedPage, source: .library)
        for page in 1...30 {
            context.player.appendToQueue(
                tracks(count: 100, idOffset: page * 100)
            )
        }

        XCTAssertEqual(
            upcomingCount(in: context.player),
            LibraryQueuePolicy.queueLimit
        )
    }

    private func upcomingCount(in player: AudioPlayer) -> Int {
        guard let index = player.currentIndex else { return 0 }
        return max(player.queue.count - index - 1, 0)
    }

    private func tracks(count: Int, idOffset: Int = 0) -> [Track] {
        (0..<count).map { index in
            Track(
                trackID: idOffset + index + 1,
                ownerID: 10,
                title: "Track \(idOffset + index + 1)",
                artist: "Artist \(index % 4)",
                duration: 180,
                streamURL: nil,
                artworkURL: nil
            )
        }
    }

    private struct PlayerContext {
        let player: AudioPlayer
        let defaults: UserDefaults
        let suite: String

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makePlayer() -> PlayerContext {
        let suite = "LibraryQueueCapacityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return PlayerContext(
            player: AudioPlayer(
                settings: AppSettings(defaults: defaults),
                historyStore: ListeningHistoryStore(defaults: defaults),
                defaults: defaults
            ),
            defaults: defaults,
            suite: suite
        )
    }
}
