import Foundation

/// Stateful VK mix cursor. The older continuation helper always requested the
/// same offsets after bootstrap; live radio needs each refill to reserve the
/// next window so unique additions keep arriving.
actor MixTrackContinuationCursor {
    private let mix: MusicMix
    private var nextOffset: Int

    init(
        mix: MusicMix,
        startingOffset: Int = MixTrackRequestPolicy.bootstrapPages
            * MixTrackRequestPolicy.pageSize
    ) {
        self.mix = mix
        self.nextOffset = max(startingOffset, 0)
    }

    func next(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        let offset = nextOffset
        let tracks = try await musicService.mixTracksContinuation(
            mix,
            accessToken: accessToken,
            startingOffset: offset
        )
        // Commit only after success — advancing first skipped a page when
        // withAuthorizedToken retried after a token refresh.
        nextOffset = offset
            + MixTrackRequestPolicy.continuationPages
            * MixTrackRequestPolicy.pageSize
        return tracks
    }
}

/// Keeps radio refills from replaying the same artists back to back: the
/// last `window` placements stay ineligible while candidates are generated.
enum RadioArtistCooldown {
    static let window = 25

    /// Drop tracks whose artist is still inside the cooldown window. If every
    /// candidate would vanish, return the input unchanged — silence is worse
    /// than a repeat.
    static func applying(
        _ tracks: [Track],
        recentArtistKeys: [String],
        window: Int = window
    ) -> [Track] {
        guard !tracks.isEmpty, window > 0, !recentArtistKeys.isEmpty else {
            return tracks
        }
        let blocked = Set(recentArtistKeys.suffix(window))
        let filtered = tracks.filter { track in
            let key = MixFeedbackPolicy.normalized(track.artist)
            return key.isEmpty || !blocked.contains(key)
        }
        return filtered.isEmpty ? tracks : filtered
    }

    /// Seed the window from a newest-first list (listening history order).
    static func artists(
        fromNewestFirst tracks: [Track],
        window: Int = window
    ) -> [String] {
        guard window > 0 else { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        keys.reserveCapacity(min(window, tracks.count))
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
            if keys.count >= window { break }
        }
        return keys
    }

    static func append(
        _ keys: inout [String],
        from tracks: [Track],
        window: Int = window
    ) {
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty else { continue }
            keys.append(key)
        }
        if keys.count > window {
            keys.removeFirst(keys.count - window)
        }
    }
}

/// Blends VK recommendation pools into one radio queue.
enum RadioRecommendationComposer {
    /// Interleave ratio: one personal, one similar, a seed every four picks.
    private static let personalPerRound = 1
    private static let similarPerRound = 1
    private static let seedEvery = 4

    static func seedTracks(
        history: [ListeningHistoryEntry],
        recommendations: [Track],
        loaded: [Track],
        limit: Int = 32
    ) -> [Track] {
        let base = unique(
            history.map(\.track) + loaded + recommendations,
            limit: limit * 2
        )
        return ArtistCooccurrenceIndex.boostSeeds(
            base,
            history: history,
            limit: limit
        )
    }

    /// Keep the seed window sliding toward freshly composed material so
    /// later fan-out rounds are not stuck on the bootstrap snapshot.
    static func rotatingSeeds(
        previous: [Track],
        composed: [Track],
        limit: Int = 32
    ) -> [Track] {
        unique(composed + previous, limit: limit)
    }

    static func compose(
        seedTracks: [Track],
        personalRecommendations: [Track],
        similarRecommendations: [Track],
        fallbackMix: [Track] = [],
        artistCap: Int = 3,
        limit: Int = MixTrackRequestPolicy.queueLimit
    ) -> [Track] {
        var known = Set<String>()
        var artistCounts: [String: Int] = [:]
        var result: [Track] = []
        var effectiveCap = artistCap
        result.reserveCapacity(limit)

        func append(_ track: Track) -> Bool {
            guard result.count < limit,
                  known.insert(track.id).inserted else {
                return false
            }
            let key = MixFeedbackPolicy.normalized(track.artist)
            if !key.isEmpty, effectiveCap > 0 {
                let count = artistCounts[key, default: 0]
                if count >= effectiveCap {
                    // Hard cap at blend time. Leave room for other artists;
                    // do not burn the slot.
                    known.remove(track.id)
                    return false
                }
                artistCounts[key] = count + 1
            }
            result.append(track)
            return true
        }

        let seeds = seedTracks.prefix(12).map { $0 }
        let personal = personalRecommendations.prefix(limit).map { $0 }
        let similar = similarRecommendations.prefix(limit).map { $0 }
        let fallback = fallbackMix.prefix(limit).map { $0 }

        var seedIndex = 0
        var personalIndex = 0
        var similarIndex = 0
        var fallbackIndex = 0
        var stalled = 0
        /// Non-seed placements since the last seed. Gating on `result.count`
        /// made each seed shift the modulo so the interleave inserted one
        /// seed and then almost never another while pools were still full.
        var sinceSeed = 0

        while result.count < limit,
              seedIndex < seeds.count
                || personalIndex < personal.count
                || similarIndex < similar.count
                || fallbackIndex < fallback.count {
            let before = result.count
            for _ in 0..<personalPerRound where personalIndex < personal.count {
                if append(personal[personalIndex]) {
                    sinceSeed += 1
                }
                personalIndex += 1
                if result.count >= limit { break }
            }
            for _ in 0..<similarPerRound where similarIndex < similar.count {
                if append(similar[similarIndex]) {
                    sinceSeed += 1
                }
                similarIndex += 1
                if result.count >= limit { break }
            }
            if sinceSeed >= seedEvery,
               seedIndex < seeds.count {
                if append(seeds[seedIndex]) {
                    sinceSeed = 0
                }
                seedIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex < fallback.count {
                if append(fallback[fallbackIndex]) {
                    sinceSeed += 1
                }
                fallbackIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex >= fallback.count,
               seedIndex < seeds.count {
                if append(seeds[seedIndex]) {
                    sinceSeed = 0
                }
                seedIndex += 1
            }
            if result.count == before {
                stalled += 1
                // Artist cap blocked every candidate — raise the cap once
                // so the queue can still fill rather than stall forever.
                if stalled == 2, effectiveCap > 0, effectiveCap < 8 {
                    effectiveCap += 2
                    stalled = 0
                } else if stalled > 2 {
                    break
                }
            } else {
                stalled = 0
            }
        }
        return result
    }

    private static func unique(_ tracks: [Track], limit: Int) -> [Track] {
        var known = Set<String>()
        var result: [Track] = []
        result.reserveCapacity(min(limit, tracks.count))
        for track in tracks where known.insert(track.id).inserted {
            result.append(track)
            if result.count >= limit { break }
        }
        return result
    }
}

/// Radio is a station, not a one-page mix: rotate through taste seeds and ask
/// VK for track-based recommendations, with personal recommendations and the
/// common mix as fallback material.
actor RadioRecommendationCursor {
    private var seeds: [Track]
    private var knownIDs: Set<String>
    private var seedIndex = 0
    private var commonMixOffset = 0
    /// Last personal recommendations page. Reused across continuation so
    /// every refill does not pay another identical network round-trip.
    private var sessionPersonal: [Track] = []
    /// Artists placed in this session's queue — hard-excluded from the
    /// next generation window (Yandex-style cooldown, not just spacing).
    private var recentArtistKeys: [String] = []

    init(seedTracks: [Track], knownTracks: [Track] = []) {
        self.seeds = RadioRecommendationComposer.seedTracks(
            history: [],
            recommendations: seedTracks,
            loaded: []
        )
        self.knownIDs = Set(knownTracks.map(\.id))
        // Call sites pass newest-first history (and session queues with the
        // hottest material first). Seed by recency, not append-then-trim.
        self.recentArtistKeys = RadioArtistCooldown.artists(
            fromNewestFirst: knownTracks
        )
    }

    func next(
        accessToken: String,
        musicService: any MusicService,
        cachedPersonalRecommendations: [Track] = []
    ) async throws -> [Track] {
        // Seed fan-out and personal taste used to run one after another —
        // four round-trips before the first paint. Run them together; the
        // wall clock is one RTT, not four.
        async let similarTracks = seededRecommendations(
            accessToken: accessToken,
            musicService: musicService
        )
        async let personalTracks = personalRecommendations(
            accessToken: accessToken,
            musicService: musicService,
            cached: cachedPersonalRecommendations
        )

        let similar = try await similarTracks
        let personal = try await personalTracks

        var fallback: [Track] = []
        if personal.isEmpty && similar.isEmpty {
            fallback = try await nextCommonMixPage(
                accessToken: accessToken,
                musicService: musicService
            )
        }

        let cooledPersonal = RadioArtistCooldown.applying(
            personal,
            recentArtistKeys: recentArtistKeys
        )
        let cooledSimilar = RadioArtistCooldown.applying(
            similar,
            recentArtistKeys: recentArtistKeys
        )
        let cooledFallback = RadioArtistCooldown.applying(
            fallback,
            recentArtistKeys: recentArtistKeys
        )

        let composed = RadioRecommendationComposer.compose(
            seedTracks: seeds,
            personalRecommendations: cooledPersonal,
            similarRecommendations: cooledSimilar,
            fallbackMix: cooledFallback
        )

        var kept: [Track] = []
        kept.reserveCapacity(composed.count)
        for track in composed where knownIDs.insert(track.id).inserted {
            kept.append(track)
        }

        if !kept.isEmpty {
            seeds = RadioRecommendationComposer.rotatingSeeds(
                previous: seeds,
                composed: kept
            )
            RadioArtistCooldown.append(
                &recentArtistKeys,
                from: kept
            )
        }
        return kept
    }

    private func personalRecommendations(
        accessToken: String,
        musicService: any MusicService,
        cached: [Track]
    ) async throws -> [Track] {
        if !cached.isEmpty {
            sessionPersonal = cached
            return cached
        }
        if !sessionPersonal.isEmpty {
            return sessionPersonal
        }
        do {
            let fresh = try await musicService.recommendations(
                accessToken: accessToken
            )
            sessionPersonal = fresh
            return fresh
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized
            || error.isConnectivityFailure {
            throw error
        } catch {
            return []
        }
    }

    private func seededRecommendations(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        guard !seeds.isEmpty else { return [] }
        let seedBatch = nextSeeds(count: 3)
        return try await withThrowingTaskGroup(of: [Track].self) { group in
            for seed in seedBatch {
                group.addTask {
                    do {
                        return try await musicService.recommendations(
                            seededBy: seed,
                            accessToken: accessToken,
                            shuffle: true
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as APIError where error == .unauthorized
                        || error.isConnectivityFailure {
                        throw error
                    } catch {
                        return []
                    }
                }
            }
            var collected: [Track] = []
            for try await tracks in group {
                collected.append(contentsOf: tracks)
            }
            return collected
        }
    }

    private func nextCommonMixPage(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        let offset = commonMixOffset
        let tracks = try await musicService.mixTracks(
            .common,
            accessToken: accessToken,
            startingOffset: offset,
            pages: 1
        )
        commonMixOffset = offset + MixTrackRequestPolicy.pageSize
        return tracks
    }

    private func nextSeeds(count: Int) -> [Track] {
        guard !seeds.isEmpty else { return [] }
        var result: [Track] = []
        for _ in 0..<min(count, seeds.count) {
            result.append(seeds[seedIndex % seeds.count])
            seedIndex += 1
        }
        return result
    }
}
