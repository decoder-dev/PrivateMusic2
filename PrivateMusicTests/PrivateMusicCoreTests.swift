import XCTest
@testable import PrivateMusic

final class NativeHashTests: XCTestCase {
    func testFNVRoundsMatchTheSwiftReference() {
        let ids = ["1_10", "1_11", "2_5"]
        var expected: UInt64 = 0xcbf2_9ce4_8422_2325
        let mix: (UInt64, UInt64) -> UInt64 = { value, byte in
            var next = value
            next ^= byte
            next &*= 0x100_0000_01b3
            return next
        }
        for (index, id) in ids.enumerated() {
            expected = mix(expected, UInt64(index + 1))
            for byte in id.utf8 {
                expected = mix(expected, UInt64(byte))
            }
        }

        var actual = pm_hash_fnv1a64_basis
        for (index, id) in ids.enumerated() {
            actual = pm_hash_fnv1a64_value(actual, UInt64(index + 1))
            var text = id
            actual = text.withUTF8 { buffer in
                pm_hash_fnv1a64_bytes(
                    actual,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
        }
        XCTAssertEqual(actual, expected)
    }

    func testIdentityHashReservesZeroForEmptyNames() {
        XCTAssertEqual(identity(of: ""), 0)
        XCTAssertNotEqual(identity(of: "alpha"), 0)
        XCTAssertEqual(identity(of: "alpha"), identity(of: "alpha"))
        XCTAssertNotEqual(identity(of: "alpha"), identity(of: "beta"))
    }

    func testHashingEmptyBytesLeavesTheAccumulatorAlone() {
        let seed: UInt64 = 12_345
        XCTAssertEqual(pm_hash_fnv1a64_bytes(seed, nil, 0), seed)
    }

    private func identity(of value: String) -> UInt64 {
        var value = value
        return value.withUTF8 { buffer in
            pm_text_identity_hash(buffer.baseAddress, Int32(buffer.count))
        }
    }
}

final class NativeTextSearchTests: XCTestCase {
    func testNativeFoldMatchesFoundationForASCIIAndCyrillic() {
        let samples = [
            "Hello World",
            "ABC123!?",
            "Привет",
            "ЁЖИК",
            "ёжик",
            "Йогурт",
            "МоЯ МуЗыКа",
            "Rock & Roll (Live) 2024",
            ""
        ]
        for sample in samples {
            let native = NativeTextSearch.withFolded(sample) { folded -> String? in
                guard let folded else { return nil }
                guard let base = folded.baseAddress else { return "" }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: base,
                        count: folded.count
                    ),
                    as: UTF8.self
                )
            }
            XCTAssertEqual(
                native,
                NativeTextSearch.foundationFolded(sample),
                "native fold must agree with Foundation for \(sample)"
            )
        }
    }

    func testNativeFoldDeclinesScriptsItDoesNotOwn() {
        for sample in ["café", "日本語", "Ї", "Ελλάδα"] {
            let declined = NativeTextSearch.withFolded(sample) { $0 == nil }
            XCTAssertTrue(
                declined,
                "\(sample) must fall back to Foundation"
            )
        }
    }

    func testMatchesAgreesWithTheFoundationPredicate() {
        let candidates = [
            "Мой Плейлист",
            "Лучшее за 2024",
            "Chill Vibes",
            "café playlist",
            "ЁЖИК в тумане",
            "Rock"
        ]
        let queries = [
            "плей", "ПЛЕЙ", "ежик", "ЁЖ", "chill", "CHILL", "café", "CAFÉ",
            "2024", "zzz"
        ]
        for query in queries {
            let needle = FoldedSearchQuery(query)
            let folded = NativeTextSearch.foundationFolded(query)
            for candidate in candidates {
                let expected = NativeTextSearch.foundationFolded(candidate)
                    .contains(folded)
                XCTAssertEqual(
                    needle.matches(candidate),
                    expected,
                    "\(query) vs \(candidate)"
                )
            }
        }
    }

    func testEmptyQueryNeverMatches() {
        let needle = FoldedSearchQuery("")
        XCTAssertTrue(needle.isEmpty)
        XCTAssertFalse(needle.matches("anything"))
        XCTAssertFalse(needle.matches(""))
    }

    func testFindReportsOffsetsAndMisses() {
        let haystack = Array("the quick brown fox".utf8)
        XCTAssertEqual(find("quick", in: haystack), 4)
        XCTAssertEqual(find("the", in: haystack), 0)
        XCTAssertEqual(find("fox", in: haystack), 16)
        XCTAssertEqual(find("cat", in: haystack), -1)
        XCTAssertEqual(find("", in: haystack), -1)
        XCTAssertEqual(find("aab", in: Array("aaab".utf8)), 1)
    }

    private func find(_ needle: String, in haystack: [UInt8]) -> Int32 {
        let needleBytes = Array(needle.utf8)
        return haystack.withUnsafeBufferPointer { haystackBuffer in
            needleBytes.withUnsafeBufferPointer { needleBuffer in
                pm_text_find(
                    haystackBuffer.baseAddress,
                    Int32(haystackBuffer.count),
                    needleBuffer.baseAddress,
                    Int32(needleBuffer.count)
                )
            }
        }
    }
}

final class NativeMixRankingTests: XCTestCase {
    private let alpha = NativeMixRankingTests.identity(of: "alpha")
    private let beta = NativeMixRankingTests.identity(of: "beta")
    private let gamma = NativeMixRankingTests.identity(of: "gamma")
    private let album = NativeMixRankingTests.identity(of: "album")

    func testCloserToSeedStacksArtistAndAlbumAffinity() {
        var context = PMMixRankContext(
            mode: Int32(PM_MIX_MODE_CLOSER_TO_SEED),
            seed_artist_hash: alpha,
            seed_album_hash: album,
            history_hashes: nil,
            history_count: 0
        )
        // 42 (seed artist) + 18 (seed album)
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: alpha, album_hash: album),
                  context: &context),
            60,
            accuracy: 0.000_001
        )
        // 4 for simply being a different artist
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: beta, album_hash: 0),
                  context: &context),
            4,
            accuracy: 0.000_001
        )
    }

    func testMoreNovelRewardsUnheardArtists() {
        let history = [alpha, beta].sorted()
        history.withUnsafeBufferPointer { buffer in
            var context = PMMixRankContext(
                mode: Int32(PM_MIX_MODE_MORE_NOVEL),
                seed_artist_hash: alpha,
                seed_album_hash: album,
                history_hashes: buffer.baseAddress,
                history_count: Int32(buffer.count)
            )
            // 32 (not the seed) + 26 (unheard) + 8 (other album) + 12 (fresh)
            XCTAssertEqual(
                score(PMMixCandidate(artist_hash: gamma, album_hash: 0),
                      context: &context),
                78,
                accuracy: 0.000_001
            )
            // 32 (not the seed) - 16 (heard) + 8 (other album) + 12 (fresh)
            XCTAssertEqual(
                score(PMMixCandidate(artist_hash: beta, album_hash: 0),
                      context: &context),
                36,
                accuracy: 0.000_001
            )
            // -18 (is the seed) - 16 (heard) + 12 (fresh)
            XCTAssertEqual(
                score(PMMixCandidate(artist_hash: alpha, album_hash: album),
                      context: &context),
                -22,
                accuracy: 0.000_001
            )
        }
    }

    func testSpacingPenaltyGrowsWithRecency() {
        var context = PMMixRankContext(
            mode: Int32(PM_MIX_MODE_CLOSER_TO_SEED),
            seed_artist_hash: 0,
            seed_album_hash: 0,
            history_hashes: nil,
            history_count: 0
        )
        let recent = [gamma, beta, alpha, beta]
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: beta, album_hash: 0),
                  context: &context, recent: recent),
            -16,
            accuracy: 0.000_001,
            "the artist that just played is penalized hardest"
        )
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: alpha, album_hash: 0),
                  context: &context, recent: recent),
            -8,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: gamma, album_hash: 0),
                  context: &context, recent: recent),
            -3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: album, album_hash: 0),
                  context: &context, recent: recent),
            0,
            accuracy: 0.000_001,
            "an unseen artist takes the fresh bonus"
        )
        XCTAssertEqual(
            score(PMMixCandidate(artist_hash: 0, album_hash: 0),
                  context: &context, recent: recent),
            0,
            accuracy: 0.000_001,
            "a nameless artist skips spacing entirely"
        )
    }

    func testSelectBestPrefersTheSeedArtistAndKeepsTiesStable() {
        var context = PMMixRankContext(
            mode: Int32(PM_MIX_MODE_CLOSER_TO_SEED),
            seed_artist_hash: alpha,
            seed_album_hash: 0,
            history_hashes: nil,
            history_count: 0
        )
        let candidates = [
            PMMixCandidate(artist_hash: beta, album_hash: 0),
            PMMixCandidate(artist_hash: alpha, album_hash: 0),
            PMMixCandidate(artist_hash: beta, album_hash: 0)
        ]
        XCTAssertEqual(
            selectBest(candidates, jitter: [0, 0, 0], context: &context),
            1
        )

        let tied = [
            PMMixCandidate(artist_hash: beta, album_hash: 0),
            PMMixCandidate(artist_hash: beta, album_hash: 0)
        ]
        XCTAssertEqual(
            selectBest(tied, jitter: [0, 0], context: &context),
            0,
            "ties keep the earlier candidate"
        )
        XCTAssertEqual(
            selectBest(tied, jitter: [0, 1.5], context: &context),
            1,
            "jitter breaks ties"
        )
        XCTAssertEqual(
            selectBest([], jitter: [], context: &context),
            0,
            "an empty candidate list falls back to index 0"
        )
    }

    private static func identity(of value: String) -> UInt64 {
        var value = value
        return value.withUTF8 { buffer in
            pm_text_identity_hash(buffer.baseAddress, Int32(buffer.count))
        }
    }

    private func score(
        _ candidate: PMMixCandidate,
        context: inout PMMixRankContext,
        jitter: Double = 0,
        recent: [UInt64] = []
    ) -> Double {
        recent.withUnsafeBufferPointer { buffer in
            pm_mix_score_candidate(
                candidate,
                jitter,
                &context,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
    }

    private func selectBest(
        _ candidates: [PMMixCandidate],
        jitter: [Double],
        context: inout PMMixRankContext,
        recent: [UInt64] = []
    ) -> Int {
        candidates.withUnsafeBufferPointer { candidateBuffer in
            jitter.withUnsafeBufferPointer { jitterBuffer in
                recent.withUnsafeBufferPointer { recentBuffer in
                    Int(
                        pm_mix_select_best(
                            candidateBuffer.baseAddress,
                            jitterBuffer.baseAddress,
                            Int32(candidates.count),
                            &context,
                            recentBuffer.baseAddress,
                            Int32(recentBuffer.count)
                        )
                    )
                }
            }
        }
    }
}

/// The C ranker must reproduce the Swift scoring it replaced, so these tests
/// rank the same queue twice: once through `MixQueueRanker`, once through a
/// literal transcription of the old string-comparing implementation.
final class MixQueueRankerNativeParityTests: XCTestCase {
    func testCloserToSeedMatchesTheSwiftReference() {
        assertParity(mode: .closerToSeed, rngSeed: 3)
        assertParity(mode: .closerToSeed, rngSeed: 17)
    }

    func testMoreNovelMatchesTheSwiftReference() {
        assertParity(mode: .moreNovel, rngSeed: 5)
        assertParity(mode: .moreNovel, rngSeed: 23)
    }

    func testStableSeedMatchesAnFNV1aReference() {
        let queue = makeQueue()
        for mode in MixRadioMode.allCases {
            for currentIndex in [0, 3, 7] {
                XCTAssertEqual(
                    MixQueueRanker.stableSeed(
                        queue: queue,
                        currentIndex: currentIndex,
                        mode: mode
                    ),
                    Self.referenceStableSeed(
                        queue: queue,
                        currentIndex: currentIndex,
                        mode: mode
                    ),
                    "\(mode) at \(currentIndex)"
                )
            }
        }
    }

    func testStableSeedSeparatesQueuesIndexesAndModes() {
        let queue = makeQueue()
        let baseline = MixQueueRanker.stableSeed(
            queue: queue,
            currentIndex: 0,
            mode: .balanced
        )
        XCTAssertEqual(
            baseline,
            MixQueueRanker.stableSeed(
                queue: queue,
                currentIndex: 0,
                mode: .balanced
            ),
            "the same snapshot must seed the same way"
        )
        XCTAssertNotEqual(
            baseline,
            MixQueueRanker.stableSeed(
                queue: queue,
                currentIndex: 1,
                mode: .balanced
            )
        )
        XCTAssertNotEqual(
            baseline,
            MixQueueRanker.stableSeed(
                queue: queue,
                currentIndex: 0,
                mode: .moreNovel
            )
        )
        XCTAssertNotEqual(
            baseline,
            MixQueueRanker.stableSeed(
                queue: Array(queue.dropLast()),
                currentIndex: 0,
                mode: .balanced
            )
        )
    }

    private func assertParity(
        mode: MixRadioMode,
        rngSeed: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let queue = makeQueue()
        let history: Set<String> = ["Beta", "Дельта"]
        var nativeRNG = SeededGenerator(seed: rngSeed)
        let native = MixQueueRanker.rerank(
            queue: queue,
            currentIndex: 0,
            seed: queue[0],
            mode: mode,
            historyArtists: history,
            rng: &nativeRNG
        )

        var referenceRNG = SeededGenerator(seed: rngSeed)
        let reference = Self.referenceRerank(
            queue: queue,
            currentIndex: 0,
            seed: queue[0],
            mode: mode,
            historyArtists: history,
            rng: &referenceRNG
        )

        XCTAssertEqual(
            native.map(\.id),
            reference.map(\.id),
            "\(mode) ranking must match the Swift reference",
            file: file,
            line: line
        )
    }

    private func makeQueue() -> [Track] {
        let artists = [
            "Alpha", "Beta", "Alpha", "Gamma", "Дельта",
            "Ёжик", "beta", "Epsilon", "Дельта", "Zeta"
        ]
        let albums: [String?] = [
            "Album One", nil, "Album One", "Album Two", nil,
            "album", "Album Two", nil, "album", "Album One"
        ]
        return artists.indices.map { index in
            Track(
                trackID: index + 1,
                ownerID: 1,
                title: "Song \(index + 1)",
                artist: artists[index],
                albumTitle: albums[index],
                duration: 180,
                streamURL: nil,
                artworkURL: nil
            )
        }
    }

    // MARK: - Reference implementation (the pre-C Swift)

    private static func referenceStableSeed(
        queue: [Track],
        currentIndex: Int,
        mode: MixRadioMode
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let mix: (UInt64, UInt64) -> UInt64 = { value, byte in
            var next = value
            next ^= byte
            next &*= 0x100_0000_01b3
            return next
        }
        for (index, track) in queue.enumerated() {
            hash = mix(hash, UInt64(index &+ 1))
            for byte in track.id.utf8 {
                hash = mix(hash, UInt64(byte))
            }
        }
        hash = mix(hash, UInt64(currentIndex &+ 1))
        for byte in mode.rawValue.utf8 {
            hash = mix(hash, UInt64(byte))
        }
        return hash == 0 ? 0x9e37_79b9_7f4a_7c15 : hash
    }

    private static func referenceRerank<G: RandomNumberGenerator>(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String>,
        rng: inout G
    ) -> [Track] {
        guard queue.indices.contains(currentIndex) else { return queue }
        let head = Array(queue.prefix(currentIndex + 1))
        let remaining = Array(queue.suffix(from: currentIndex + 1))
        guard remaining.count > 1 else { return queue }

        let seedArtist = normalized(seed.artist)
        let seedAlbum = seed.albumTitle.map(normalized) ?? ""
        let history = Set(historyArtists.map(normalized))

        var pool = remaining
        var recentArtists = head.suffix(4).map { normalized($0.artist) }
        var built: [Track] = []
        built.reserveCapacity(pool.count)

        while !pool.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.greatestFiniteMagnitude
            for (index, track) in pool.enumerated() {
                let value = score(
                    track,
                    seedArtist: seedArtist,
                    seedAlbum: seedAlbum,
                    history: history,
                    recentArtists: recentArtists,
                    mode: mode,
                    rng: &rng
                )
                if value > bestScore {
                    bestScore = value
                    bestIndex = index
                }
            }
            let picked = pool.remove(at: bestIndex)
            built.append(picked)
            recentArtists.append(normalized(picked.artist))
            if recentArtists.count > 5 {
                recentArtists.removeFirst(recentArtists.count - 5)
            }
        }
        return head + built
    }

    private static func score<G: RandomNumberGenerator>(
        _ track: Track,
        seedArtist: String,
        seedAlbum: String,
        history: Set<String>,
        recentArtists: [String],
        mode: MixRadioMode,
        rng: inout G
    ) -> Double {
        let artist = normalized(track.artist)
        let album = track.albumTitle.map(normalized) ?? ""
        var value = 0.0

        switch mode {
        case .balanced:
            break
        case .closerToSeed:
            if !seedArtist.isEmpty, artist == seedArtist { value += 42 }
            if !seedAlbum.isEmpty, album == seedAlbum { value += 18 }
            if history.contains(artist) { value += 6 }
            if !seedArtist.isEmpty, artist != seedArtist { value += 4 }
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -16,
                near: -8,
                window: -3,
                fresh: 0
            )
            value += Double.random(in: 0..<3, using: &rng)

        case .moreNovel:
            if !seedArtist.isEmpty, artist != seedArtist { value += 32 }
            if !seedArtist.isEmpty, artist == seedArtist { value -= 18 }
            if !history.contains(artist) { value += 26 }
            if history.contains(artist) { value -= 16 }
            if !seedAlbum.isEmpty, album != seedAlbum { value += 8 }
            value += spacingBonus(
                artist: artist,
                recent: recentArtists,
                immediate: -55,
                near: -28,
                window: -12,
                fresh: 12
            )
            value += Double.random(in: 0..<10, using: &rng)
        }

        return value
    }

    private static func spacingBonus(
        artist: String,
        recent: [String],
        immediate: Double,
        near: Double,
        window: Double,
        fresh: Double
    ) -> Double {
        guard !artist.isEmpty else { return 0 }
        guard !recent.isEmpty else { return fresh }
        if recent.last == artist { return immediate }
        if recent.suffix(2).contains(artist) { return near }
        if recent.contains(artist) { return window }
        return fresh
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class NativeBufferHealthTests: XCTestCase {
    func testSteadyHealthyFeedReportsHighThroughputAndNoUnderrun() {
        let estimator = BufferHealthEstimator()
        var now: TimeInterval = 0
        var loaded: TimeInterval = 0
        estimator.observe(now: now, loadedAheadSeconds: loaded)

        // Loaded-ahead grows by a full wall-second every tick: downloading
        // at twice normal playback speed, so the buffer keeps filling.
        for _ in 0..<5 {
            now += 1.0
            loaded += 1.0
            estimator.observe(now: now, loadedAheadSeconds: loaded)
        }

        XCTAssertEqual(estimator.throughput, 2.0, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(estimator.throughput, 1.0)
        XCTAssertEqual(
            estimator.predictedUnderrun(playRate: 1.0),
            BufferHealthEstimator.noUnderrun,
            "a buffer that is filling, not draining, must never predict an underrun"
        )
    }

    func testBandwidthCollapseDropsThroughputAndBringsUnderrunCloser() {
        let estimator = BufferHealthEstimator()
        var now: TimeInterval = 0
        var loaded: TimeInterval = 5.0
        estimator.observe(now: now, loadedAheadSeconds: loaded)

        // Loaded-ahead shrinks every tick: downloads are no longer keeping
        // up with playback, so the buffer drains toward empty.
        for _ in 0..<4 {
            now += 1.0
            loaded -= 0.4
            estimator.observe(now: now, loadedAheadSeconds: loaded)
        }

        XCTAssertEqual(estimator.throughput, 0.6, accuracy: 0.000_001)
        XCTAssertLessThan(estimator.throughput, 1.0)

        let underrun = estimator.predictedUnderrun(playRate: 1.0)
        XCTAssertEqual(underrun, 8.5, accuracy: 0.000_001)
        XCTAssertLessThan(
            underrun,
            BufferHealthEstimator.noUnderrun,
            "a draining buffer must predict a bounded time-to-empty, not the sentinel"
        )
    }

    func testRingWraparoundStaysBoundedAndReflectsOnlyRecentWindow() {
        let estimator = BufferHealthEstimator()
        let capacity = Int(PM_BUFFER_HEALTH_WINDOW_CAPACITY)
        let overflow = 8
        var now: TimeInterval = 0
        var loaded: TimeInterval = 0
        estimator.observe(now: now, loadedAheadSeconds: loaded)

        // Fill the entire window with a fast feed (rate 3.0/tick).
        for _ in 0..<capacity {
            now += 1.0
            loaded += 2.0
            estimator.observe(now: now, loadedAheadSeconds: loaded)
        }
        // Push past capacity with a slow feed (rate 0.5/tick). A bounded
        // ring must evict the oldest fast samples one-for-one rather than
        // growing memory or drifting toward an all-time average.
        for _ in 0..<overflow {
            now += 1.0
            loaded -= 0.5
            estimator.observe(now: now, loadedAheadSeconds: loaded)
        }

        let keptFast = Double(capacity - overflow)
        let keptSlow = Double(overflow)
        let expectedWindowedAverage =
            (keptFast * 3.0 + keptSlow * 0.5) / Double(capacity)
        let unboundedAverage =
            (Double(capacity) * 3.0 + keptSlow * 0.5) / Double(capacity + overflow)

        XCTAssertEqual(
            estimator.throughput,
            expectedWindowedAverage,
            accuracy: 0.000_001,
            "must reflect only the most recent \(capacity) samples"
        )
        XCTAssertNotEqual(
            estimator.throughput,
            unboundedAverage,
            accuracy: 0.05,
            "an unbounded average would still be dragged up by the evicted fast samples"
        )
    }

    func testSameInputSequenceProducesDeterministicOutputs() {
        func feed(_ estimator: BufferHealthEstimator) {
            var now: TimeInterval = 0
            var loaded: TimeInterval = 2.0
            estimator.observe(now: now, loadedAheadSeconds: loaded)
            let deltas: [TimeInterval] = [0.8, -0.3, 0.5, -0.6, 0.1, -0.2]
            for delta in deltas {
                now += 0.5
                loaded += delta
                estimator.observe(now: now, loadedAheadSeconds: loaded)
            }
        }

        let first = BufferHealthEstimator()
        let second = BufferHealthEstimator()
        feed(first)
        feed(second)

        XCTAssertEqual(first.throughput, second.throughput, accuracy: 0.000_001)
        XCTAssertEqual(
            first.predictedUnderrun(playRate: 1.0),
            second.predictedUnderrun(playRate: 1.0),
            accuracy: 0.000_001
        )

        // A reset clears history, so the same estimator replaying the same
        // sequence again must reproduce its own first pass exactly.
        first.reset()
        feed(first)
        XCTAssertEqual(first.throughput, second.throughput, accuracy: 0.000_001)
    }

    func testFirstObserveOnlySeedsAndDoesNotYetProduceARate() {
        let estimator = BufferHealthEstimator()
        estimator.observe(now: 0, loadedAheadSeconds: 3.0)

        XCTAssertEqual(
            estimator.throughput,
            1.0,
            "before a second sample there is no time delta to rate, so the estimator reports steady"
        )
        XCTAssertEqual(
            estimator.predictedUnderrun(playRate: 1.0),
            BufferHealthEstimator.noUnderrun
        )
    }

    func testNonPositivePlayRateNeverPredictsAnUnderrun() {
        let estimator = BufferHealthEstimator()
        var now: TimeInterval = 0
        var loaded: TimeInterval = 5.0
        estimator.observe(now: now, loadedAheadSeconds: loaded)
        for _ in 0..<3 {
            now += 1.0
            loaded -= 0.4
            estimator.observe(now: now, loadedAheadSeconds: loaded)
        }

        XCTAssertEqual(
            estimator.predictedUnderrun(playRate: 0.0),
            BufferHealthEstimator.noUnderrun,
            "paused playback (rate 0) never drains the buffer"
        )
    }

    func testNonMonotonicTickIsDroppedInsteadOfCorruptingTheRate() {
        let estimator = BufferHealthEstimator()
        estimator.observe(now: 0, loadedAheadSeconds: 5.0)
        estimator.observe(now: 1.0, loadedAheadSeconds: 4.6)
        let throughputBeforeGlitch = estimator.throughput

        // A duplicate/out-of-order tick at (or before) the same timestamp
        // must not be folded into the rolling rate.
        estimator.observe(now: 1.0, loadedAheadSeconds: 999.0)
        XCTAssertEqual(estimator.throughput, throughputBeforeGlitch, accuracy: 0.000_001)

        estimator.observe(now: 2.0, loadedAheadSeconds: 4.2)
        XCTAssertEqual(estimator.throughput, 0.6, accuracy: 0.000_001)
    }
}

/// Deterministic RNG (SplitMix64) so parity runs draw the same sequence.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
