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

enum SelenaRecommendationComposer {
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
        diversity: SelenaDiversityPreference = .default,
        bias: (personal: Int, similar: Int, seedEvery: Int)? = nil,
        artistCap: Int = 3,
        limit: Int = MixTrackRequestPolicy.queueLimit
    ) -> (tracks: [Track], sources: [String: SelenaComposeSource]) {
        var known = Set<String>()
        var artistCounts: [String: Int] = [:]
        var result: [Track] = []
        var sources: [String: SelenaComposeSource] = [:]
        var effectiveCap = artistCap
        result.reserveCapacity(limit)

        func append(_ track: Track, source: SelenaComposeSource) -> Bool {
            guard result.count < limit,
                  known.insert(track.id).inserted else {
                return false
            }
            let key = MixFeedbackPolicy.normalized(track.artist)
            if !key.isEmpty, effectiveCap > 0 {
                let count = artistCounts[key, default: 0]
                if count >= effectiveCap {
                    // Hard cap at blend time (troi-style). Leave room for
                    // other artists; do not burn the slot.
                    known.remove(track.id)
                    return false
                }
                artistCounts[key] = count + 1
            }
            result.append(track)
            sources[track.id] = source
            return true
        }

        let resolvedBias = bias ?? SelenaWavePolicy.composeBias(diversity: diversity)
        let seeds = seedTracks.prefix(12).map { $0 }
        let personal = personalRecommendations.prefix(limit).map { $0 }
        let similar = similarRecommendations.prefix(limit).map { $0 }
        let fallback = fallbackMix.prefix(limit).map { $0 }

        var seedIndex = 0
        var personalIndex = 0
        var similarIndex = 0
        var fallbackIndex = 0
        var stalled = 0

        while result.count < limit,
              seedIndex < seeds.count
                || personalIndex < personal.count
                || similarIndex < similar.count
                || fallbackIndex < fallback.count {
            let before = result.count
            for _ in 0..<resolvedBias.personal where personalIndex < personal.count {
                _ = append(personal[personalIndex], source: .personal)
                personalIndex += 1
                if result.count >= limit { break }
            }
            for _ in 0..<resolvedBias.similar where similarIndex < similar.count {
                _ = append(similar[similarIndex], source: .similar)
                similarIndex += 1
                if result.count >= limit { break }
            }
            if result.count % max(resolvedBias.seedEvery, 1) == 0,
               seedIndex < seeds.count {
                _ = append(seeds[seedIndex], source: .seed)
                seedIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex < fallback.count {
                _ = append(fallback[fallbackIndex], source: .fallback)
                fallbackIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex >= fallback.count,
               seedIndex < seeds.count {
                _ = append(seeds[seedIndex], source: .seed)
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
        return (result, sources)
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

/// Selena is a station, not a one-page mix: rotate through taste seeds and ask
/// VK for track-based recommendations, with personal recommendations and the
/// common mix as fallback material.
actor SelenaRecommendationCursor {
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
        self.seeds = SelenaRecommendationComposer.seedTracks(
            history: [],
            recommendations: seedTracks,
            loaded: []
        )
        self.knownIDs = Set(knownTracks.map(\.id))
        // Call sites pass newest-first history (and session queues with the
        // hottest material first). Seed by recency, not append-then-trim.
        self.recentArtistKeys = SelenaWavePolicy.cooldownArtists(
            fromNewestFirst: knownTracks
        )
    }

    func next(
        accessToken: String,
        musicService: any MusicService,
        cachedPersonalRecommendations: [Track] = [],
        diversity: SelenaDiversityPreference = .default,
        bias: (personal: Int, similar: Int, seedEvery: Int)? = nil
    ) async throws -> (tracks: [Track], sources: [String: SelenaComposeSource]) {
        // Seed fan-out and personal taste used to run one after another —
        // four round-trips before Explore could paint Selena. Run them
        // together; the wall clock is one RTT, not four.
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

        let cooledPersonal = SelenaWavePolicy.applyingArtistCooldown(
            personal,
            recentArtistKeys: recentArtistKeys
        )
        let cooledSimilar = SelenaWavePolicy.applyingArtistCooldown(
            similar,
            recentArtistKeys: recentArtistKeys
        )
        let cooledFallback = SelenaWavePolicy.applyingArtistCooldown(
            fallback,
            recentArtistKeys: recentArtistKeys
        )

        let composed = SelenaRecommendationComposer.compose(
            seedTracks: seeds,
            personalRecommendations: cooledPersonal,
            similarRecommendations: cooledSimilar,
            fallbackMix: cooledFallback,
            diversity: diversity,
            bias: bias
        )

        var kept: [Track] = []
        var keptSources: [String: SelenaComposeSource] = [:]
        kept.reserveCapacity(composed.tracks.count)
        for track in composed.tracks where knownIDs.insert(track.id).inserted {
            kept.append(track)
            if let source = composed.sources[track.id] {
                keptSources[track.id] = source
            }
        }

        if !kept.isEmpty {
            seeds = SelenaRecommendationComposer.rotatingSeeds(
                previous: seeds,
                composed: kept
            )
            SelenaWavePolicy.appendCooldownArtists(
                &recentArtistKeys,
                from: kept
            )
        }
        return (kept, keptSources)
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
        commonMixOffset += MixTrackRequestPolicy.pageSize
        return try await musicService.mixTracks(
            .common,
            accessToken: accessToken,
            startingOffset: offset,
            pages: 1
        )
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
