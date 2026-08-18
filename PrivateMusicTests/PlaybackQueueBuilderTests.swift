import XCTest
@testable import PrivateMusic

final class PlaybackQueueBuilderTests: XCTestCase {
    func testMixRadioAppendNeverRequestsServerRefill() {
        for mode in MixRadioMode.allCases {
            XCTAssertFalse(
                MixRadioRefillPolicy.shouldRefillFromServer(
                    triggeredByAppend: true,
                    mode: mode
                ),
                "\(mode) append must not wipe the queue via replaceUpcoming"
            )
        }
        XCTAssertTrue(
            MixRadioRefillPolicy.shouldRefillFromServer(
                triggeredByAppend: false,
                mode: .closerToSeed
            )
        )
        XCTAssertTrue(
            MixRadioRefillPolicy.shouldRefillFromServer(
                triggeredByAppend: false,
                mode: .moreNovel
            )
        )
        XCTAssertFalse(
            MixRadioRefillPolicy.shouldRefillFromServer(
                triggeredByAppend: false,
                mode: .balanced
            )
        )
    }

    func testStaleMixRadioRefillIsRejected() {
        XCTAssertFalse(
            MixRadioRefillPolicy.shouldApplyRefill(
                taskGeneration: 1,
                currentGeneration: 2,
                expectedMode: .closerToSeed,
                currentMode: .closerToSeed,
                expectedSeedID: "a",
                currentTrackID: "a",
                isMixQueue: true
            )
        )
        XCTAssertFalse(
            MixRadioRefillPolicy.shouldApplyRefill(
                taskGeneration: 1,
                currentGeneration: 1,
                expectedMode: .closerToSeed,
                currentMode: .moreNovel,
                expectedSeedID: "a",
                currentTrackID: "a",
                isMixQueue: true
            )
        )
        XCTAssertFalse(
            MixRadioRefillPolicy.shouldApplyRefill(
                taskGeneration: 1,
                currentGeneration: 1,
                expectedMode: .closerToSeed,
                currentMode: .closerToSeed,
                expectedSeedID: "a",
                currentTrackID: "b",
                isMixQueue: true
            )
        )
        XCTAssertFalse(
            MixRadioRefillPolicy.shouldApplyRefill(
                taskGeneration: 1,
                currentGeneration: 1,
                expectedMode: .closerToSeed,
                currentMode: .closerToSeed,
                expectedSeedID: "a",
                currentTrackID: "a",
                isMixQueue: false
            )
        )
        XCTAssertTrue(
            MixRadioRefillPolicy.shouldApplyRefill(
                taskGeneration: 3,
                currentGeneration: 3,
                expectedMode: .moreNovel,
                currentMode: .moreNovel,
                expectedSeedID: "seed",
                currentTrackID: "seed",
                isMixQueue: true
            )
        )
    }

    func testPlayNextPinsSurviveRadioUpcomingMerge() {
        let head = [track(id: 1, title: "Now")]
        let pinned = track(id: 99, title: "Play Next")
        let existing = [pinned, track(id: 2), track(id: 3)]
        let replacement = [track(id: 4), track(id: 5), track(id: 99, title: "Dup")]
        let merged = MixRadioUpcomingMergePolicy.merge(
            head: head,
            existingUpcoming: existing,
            replacement: replacement,
            pinnedIDs: [pinned.id],
            limit: 10
        )
        XCTAssertEqual(
            merged.map(\.id),
            [head[0].id, pinned.id, "10_4", "10_5"]
        )
    }

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

final class PlaybackPreloadPolicyTests: XCTestCase {
    func testPreloadsOnlyImmediateNextTrack() {
        XCTAssertEqual(
            PlaybackPreloadPolicy.nextIndex(
                queueCount: 4,
                currentIndex: 1,
                repeatMode: .off
            ),
            2
        )
    }

    func testRepeatAllPreloadsFirstTrackAtQueueEnd() {
        XCTAssertEqual(
            PlaybackPreloadPolicy.nextIndex(
                queueCount: 4,
                currentIndex: 3,
                repeatMode: .all
            ),
            0
        )
        XCTAssertNil(
            PlaybackPreloadPolicy.nextIndex(
                queueCount: 4,
                currentIndex: 3,
                repeatMode: .off
            )
        )
    }

    func testSingleTrackDoesNotCreateSpeculativePreload() {
        XCTAssertNil(
            PlaybackPreloadPolicy.nextIndex(
                queueCount: 1,
                currentIndex: 0,
                repeatMode: .all
            )
        )
    }

    func testPreparedTrackExpiresAndRejectsChangedURL() {
        let original = URL(string: "https://example.com/original.m3u8")!
        let changed = URL(string: "https://example.com/refreshed.m3u8")!
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            PlaybackPreloadPolicy.isValid(
                trackID: "track",
                url: original,
                preparedTrackID: "track",
                preparedURL: original,
                preparedAt: now.addingTimeInterval(-30),
                now: now
            )
        )
        XCTAssertFalse(
            PlaybackPreloadPolicy.isValid(
                trackID: "track",
                url: changed,
                preparedTrackID: "track",
                preparedURL: original,
                preparedAt: now.addingTimeInterval(-30),
                now: now
            )
        )
        XCTAssertFalse(
            PlaybackPreloadPolicy.isValid(
                trackID: "track",
                url: original,
                preparedTrackID: "track",
                preparedURL: original,
                preparedAt: now.addingTimeInterval(
                    -PlaybackPreloadPolicy.maximumAge - 1
                ),
                now: now
            )
        )
    }
}

final class ContinuationAdvancePolicyTests: XCTestCase {
    func testAutomaticAdvanceRequiresCurrentPlaybackIntent() {
        XCTAssertTrue(
            ContinuationAdvancePolicy.shouldAdvance(
                requested: true,
                playbackIntended: true
            )
        )
        XCTAssertFalse(
            ContinuationAdvancePolicy.shouldAdvance(
                requested: true,
                playbackIntended: false
            )
        )
        XCTAssertFalse(
            ContinuationAdvancePolicy.shouldAdvance(
                requested: false,
                playbackIntended: true
            )
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
        context.player.configureContinuation { [self] in
            requestCount += 1
            try await Task.sleep(for: .milliseconds(120))
            return [second] + refillPadding()
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

    func testContinuationPrefetchesImmediatelyWithoutAdvancing() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation { [self] in
            requestCount += 1
            return [second] + refillPadding()
        }

        context.player.play(first, in: [first])

        await waitUntil {
            context.player.queue.prefix(2).map(\.id) == [first.id, second.id]
        }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        XCTAssertEqual(context.player.currentIndex, 0)
    }

    func testContinuationPrefetchChainsWhileUpcomingWindowIsStillShort()
        async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation {
            requestCount += 1
            return [
                self.track(
                    id: 100 + requestCount,
                    duration: 200,
                    streamURL: silentWAVURL
                )
            ]
        }

        context.player.play(first, in: [first])

        await waitUntil {
            context.player.queue.count
                > MixTrackRequestPolicy.continuationRemainingThreshold + 1
        }
        XCTAssertGreaterThan(requestCount, 1)
        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        XCTAssertEqual(context.player.currentIndex, 0)
    }

    func testContinuationRetriesProviderOnceWithoutPresentingError() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 245, streamURL: silentWAVURL)
        var requestCount = 0
        context.player.configureContinuation { [self] in
            requestCount += 1
            if requestCount == 1 {
                throw APIError.timedOut
            }
            return [second] + refillPadding()
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
        context.player.configureContinuation { [self] in
            requestCount += 1
            return requestCount == 1
                ? [first, first]
                : [first, second] + refillPadding()
        }
        context.player.play(first, in: [first])

        context.player.next()

        await waitUntil {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            context.player.queue.prefix(2).map(\.id),
            [first.id, second.id]
        )
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

        await waitUntil(timeout: 25) {
            context.player.currentTrack?.id == second.id
        }
        XCTAssertGreaterThanOrEqual(
            refreshedIDs.filter { $0 == first.id }.count,
            StreamFailureRetryPolicy.maximumSameTrackAttempts
        )
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testConnectivityStreamFailureDoesNotAutoAdvance() async {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180)
        let second = track(id: 2, duration: 245)
        var refreshCount = 0
        context.player.configureStreamRefresh { _ in
            refreshCount += 1
            throw APIError.timedOut
        }

        context.player.play(first, in: [first, second])

        try? await Task.sleep(for: .seconds(4))
        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        XCTAssertGreaterThanOrEqual(refreshCount, 1)
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
        context.player.configureContinuation { [self] in
            requestCount += 1
            let fresh = track(
                id: 400 + requestCount,
                duration: 210,
                streamURL: silentWAVURL
            )
            let batch = requestCount == 1 ? [continuation] : [fresh]
            try await Task.sleep(for: .milliseconds(500))
            return batch
        }
        context.player.play(second, in: [first, second])
        context.player.errorMessage = nil
        context.player.next()

        await waitUntil { requestCount == 1 }
        context.player.previous()
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        // Stepping back is allowed to start a fresh refill — what must not
        // land is the batch that was already in flight when it happened.
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
        context.player.configureContinuation { [self] in
            requestCount += 1
            let fresh = track(
                id: 500 + requestCount,
                duration: 210,
                streamURL: silentWAVURL
            )
            let batch = requestCount == 1 ? [continuation] : [fresh]
            try await Task.sleep(for: .milliseconds(500))
            return batch
        }
        context.player.play(second, in: [first, second])
        context.player.errorMessage = nil
        context.player.next()

        await waitUntil { requestCount == 1 }
        context.player.jump(to: 0)
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(context.player.currentTrack?.id, first.id)
        // As with `previous()`: the shorter queue may start a fresh refill,
        // but the batch that was in flight must not land.
        XCTAssertFalse(context.player.queue.contains {
            $0.id == continuation.id
        })
        XCTAssertNil(context.player.errorMessage)
    }

    func testRemovingTrackBeforeCurrentPreservesCurrentTrack() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        let third = track(id: 3, duration: 220, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second, third])

        context.player.removeFromQueue(at: 0)

        XCTAssertEqual(context.player.queue.map(\.id), [second.id, third.id])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testMovingEarlierTrackToPlayNextPreservesCurrentTrack() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        let third = track(id: 3, duration: 220, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second, third])

        context.player.playNext(first)

        XCTAssertEqual(
            context.player.queue.map(\.id),
            [second.id, first.id, third.id]
        )
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testPlayLastAppendsAfterUpcomingTracks() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        let third = track(id: 3, duration: 220, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second, third])

        context.player.playLast(first)

        XCTAssertEqual(
            context.player.queue.map(\.id),
            [second.id, third.id, first.id]
        )
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testRemovingTrackAfterCurrentPreservesCurrentIndex() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        let third = track(id: 3, duration: 220, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second, third])

        context.player.removeFromQueue(at: 2)

        XCTAssertEqual(context.player.queue.map(\.id), [first.id, second.id])
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.currentTrack?.id, second.id)
    }

    func testRemovingCurrentTrackAdvancesAndPreservesPauseState() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        let third = track(id: 3, duration: 220, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second, third])
        context.player.pause()

        context.player.removeFromQueue(at: 1)

        XCTAssertEqual(context.player.queue.map(\.id), [first.id, third.id])
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.currentTrack?.id, third.id)
        XCTAssertEqual(context.player.elapsedTime, 0)
        XCTAssertFalse(context.player.isPlaying)
    }

    func testRemovingLastCurrentTrackFallsBackToPrevious() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let first = track(id: 1, duration: 180, streamURL: silentWAVURL)
        let second = track(id: 2, duration: 200, streamURL: silentWAVURL)
        context.player.play(second, in: [first, second])

        context.player.removeFromQueue(at: 1)

        XCTAssertEqual(context.player.queue.map(\.id), [first.id])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, first.id)
    }

    func testRemovingOnlyQueueItemStopsPlayback() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let only = track(id: 1, duration: 180, streamURL: silentWAVURL)
        context.player.play(only, in: [only])

        context.player.removeFromQueue(at: 0)

        XCTAssertTrue(context.player.queue.isEmpty)
        XCTAssertNil(context.player.currentIndex)
        XCTAssertNil(context.player.currentTrack)
        XCTAssertFalse(context.player.isPlaying)
    }

    func testAppendCapacityUsesUpcomingWindowNotPlayedHistory() {
        let context = makePlayer()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
        }
        let tracks = (1...75).map {
            track(id: $0, duration: 180, streamURL: silentWAVURL)
        }
        let selected = tracks[70]
        let additions = (100...109).map {
            track(id: $0, duration: 180, streamURL: silentWAVURL)
        }

        context.player.play(selected, in: tracks)
        context.player.appendToQueue(additions)

        for addition in additions {
            XCTAssertTrue(context.player.queue.contains(addition))
        }
        XCTAssertEqual(context.player.currentTrack?.id, selected.id)
        XCTAssertEqual(context.player.currentIndex, 70)
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

    /// Filler that carries the upcoming window past
    /// `continuationRemainingThreshold`.
    ///
    /// Radio refills chain while the queue is still short, so a provider that
    /// hands back a single track is asked again immediately and no exact
    /// request count is stable. Tests that count requests want one batch that
    /// actually satisfies the window.
    private func refillPadding() -> [Track] {
        (1...MixTrackRequestPolicy.continuationRemainingThreshold).map {
            track(id: 900 + $0, duration: 200, streamURL: silentWAVURL)
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
