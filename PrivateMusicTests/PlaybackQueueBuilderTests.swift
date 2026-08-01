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

    func testUniqueAdditionsExcludeQueueAndCandidateDuplicates() {
        let existing = [track(id: 1), track(id: 2)]
        let result = PlaybackQueueBuilder.uniqueAdditions(
            existing: existing,
            candidates: [
                track(id: 2),
                track(id: 3),
                track(id: 3),
                track(id: 4)
            ]
        )

        XCTAssertEqual(result.map(\.id), ["10_3", "10_4"])
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
    func testPlayerPresentationIsIdempotentAndStopAlwaysDismisses() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }

        context.player.presentPlayer()
        context.player.presentPlayer()
        XCTAssertTrue(context.player.isPlayerPresented)

        context.player.dismissPlayer()
        context.player.dismissPlayer()
        XCTAssertFalse(context.player.isPlayerPresented)

        context.player.presentPlayer()
        context.player.stop()
        XCTAssertFalse(context.player.isPlayerPresented)
    }

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

    func testContinuationIsDeduplicatedAndResetsProgress() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            try await Task.sleep(for: .milliseconds(120))
            return [second]
        }
        context.player.play(first, in: [first])
        context.player.seek(to: 73)
        context.player.errorMessage = nil

        context.player.next()
        context.player.next()
        context.player.next()

        await waitUntil {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(context.player.elapsedTime, 0)
        XCTAssertEqual(context.player.duration, second.duration)
        XCTAssertNil(context.player.errorMessage)
    }

    func testContinuationRetriesProviderOnceWithoutPresentingError() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            if requestCount == 1 {
                throw APIError.timedOut
            }
            return [second]
        }
        context.player.play(first, in: [first])
        context.player.errorMessage = nil

        context.player.next()

        await waitUntil {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(context.player.errorMessage)
    }

    func testContinuationRequestsAnotherBatchWhenFirstHasOnlyDuplicates()
        async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            return requestCount == 1 ? [first, first] : [first, second]
        }
        context.player.play(first, in: [first])

        context.player.next()

        await waitUntil {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(context.player.queue.map(\.id), [first.id, second.id])
        XCTAssertNil(context.player.errorMessage)
    }

    func testFailedStreamRefreshAdvancesWhenPolicyIsEnabled() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180)
        let second = track(id: 2, duration: 245)
        var refreshedIDs: [String] = []
        context.player.configureStreamRefresh { track in
            refreshedIDs.append(track.id)
            throw APIError.invalidResponse
        }

        context.player.play(first, in: [first, second])

        await waitUntil {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertEqual(refreshedIDs.first, first.id)
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testPreviousCancelsPendingContinuation() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        let continuation = track(id: 3, duration: 210, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            try await Task.sleep(for: .milliseconds(500))
            return [continuation]
        }
        context.player.play(second, in: [first, second])
        context.player.errorMessage = nil
        context.player.next()

        await waitUntil { requestCount == 1 }
        context.player.previous()
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        XCTAssertFalse(context.player.queue.contains {
            $0.id == continuation.id
        })
        XCTAssertNil(context.player.errorMessage)
    }

    func testJumpCancelsPendingContinuation() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        let continuation = track(id: 3, duration: 210, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            try await Task.sleep(for: .milliseconds(500))
            return [continuation]
        }
        context.player.play(second, in: [first, second])
        context.player.errorMessage = nil
        context.player.next()

        await waitUntil { requestCount == 1 }
        context.player.jump(to: 0)
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        XCTAssertFalse(context.player.queue.contains {
            $0.id == continuation.id
        })
        XCTAssertNil(context.player.errorMessage)
    }

    func testFailedContinuationDoesNotExposeModalError() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            throw APIError.unauthorized
        }
        context.player.play(first, in: [first])
        context.player.errorMessage = nil

        context.player.next()

        await waitUntil { requestCount == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(context.player.queue.map(\.id), [first.id])
        XCTAssertNil(context.player.errorMessage)
    }

    private func makePlayer() -> (
        player: AudioPlayer,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "AudioPlayerTransitionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let history = ListeningHistoryStore(defaults: defaults)
        return (
            AudioPlayer(
                settings: settings,
                historyStore: history,
                defaults: defaults
            ),
            defaults,
            suite
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func track(
        id: Int,
        duration: TimeInterval,
        streamURL: URL? = nil
    ) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: "Track \(id)",
            artist: "Artist",
            duration: duration,
            streamURL: streamURL,
            artworkURL: nil
        )
    }
}

/// Local, deterministic audio source for player tests: AVPlayer reports
/// `.failed` for unreachable HTTP URLs on the CI simulator, which would
/// surface as a playback error message. A valid WAV file loads cleanly
/// without touching the network.
private let silentWAVURL: URL = {
    let sampleRate: UInt32 = 8000
    let sampleCount = sampleRate * 120
    let byteRate = sampleRate * 2
    var data = Data(capacity: Int(44 + sampleCount * 2))
    func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) {
            data.append(contentsOf: $0)
        }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    appendLittleEndian(UInt32(36 + sampleCount * 2))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendLittleEndian(UInt32(16))
    appendLittleEndian(UInt16(1))
    appendLittleEndian(UInt16(1))
    appendLittleEndian(sampleRate)
    appendLittleEndian(byteRate)
    appendLittleEndian(UInt16(2))
    appendLittleEndian(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    appendLittleEndian(UInt32(sampleCount * 2))
    data.append(
        contentsOf: repeatElement(0, count: Int(sampleCount * 2))
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("silent-\(UUID().uuidString).wav")
    try? data.write(to: url)
    return url
}()
