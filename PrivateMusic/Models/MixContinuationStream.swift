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
        nextOffset += MixTrackRequestPolicy.continuationPages
            * MixTrackRequestPolicy.pageSize
        return try await musicService.mixTracksContinuation(
            mix,
            accessToken: accessToken,
            startingOffset: offset
        )
    }
}

enum SelenaRecommendationComposer {
    static func seedTracks(
        history: [ListeningHistoryEntry],
        recommendations: [Track],
        loaded: [Track],
        limit: Int = 32
    ) -> [Track] {
        unique(
            history.map(\.track) + loaded + recommendations,
            limit: limit
        )
    }

    static func compose(
        seedTracks: [Track],
        personalRecommendations: [Track],
        similarRecommendations: [Track],
        fallbackMix: [Track] = [],
        limit: Int = MixTrackRequestPolicy.queueLimit
    ) -> [Track] {
        var known = Set<String>()
        var result: [Track] = []
        result.reserveCapacity(limit)

        func append(_ track: Track) {
            guard result.count < limit,
                  known.insert(track.id).inserted else {
                return
            }
            result.append(track)
        }

        let seeds = seedTracks.prefix(12).map { $0 }
        let personal = personalRecommendations.prefix(limit).map { $0 }
        let similar = similarRecommendations.prefix(limit).map { $0 }
        let fallback = fallbackMix.prefix(limit).map { $0 }

        var seedIndex = 0
        var personalIndex = 0
        var similarIndex = 0
        var fallbackIndex = 0

        while result.count < limit,
              seedIndex < seeds.count
                || personalIndex < personal.count
                || similarIndex < similar.count
                || fallbackIndex < fallback.count {
            if personalIndex < personal.count {
                append(personal[personalIndex])
                personalIndex += 1
            }
            if similarIndex < similar.count {
                append(similar[similarIndex])
                similarIndex += 1
            }
            if result.count % 4 == 0, seedIndex < seeds.count {
                append(seeds[seedIndex])
                seedIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex < fallback.count {
                append(fallback[fallbackIndex])
                fallbackIndex += 1
            }
            if personalIndex >= personal.count,
               similarIndex >= similar.count,
               fallbackIndex >= fallback.count,
               seedIndex < seeds.count {
                append(seeds[seedIndex])
                seedIndex += 1
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

/// Selena is a station, not a one-page mix: rotate through taste seeds and ask
/// VK for track-based recommendations, with personal recommendations and the
/// common mix as fallback material.
actor SelenaRecommendationCursor {
    private var seeds: [Track]
    private var knownIDs: Set<String>
    private var seedIndex = 0
    private var commonMixOffset = 0

    init(seedTracks: [Track], knownTracks: [Track] = []) {
        self.seeds = SelenaRecommendationComposer.seedTracks(
            history: [],
            recommendations: seedTracks,
            loaded: []
        )
        self.knownIDs = Set(knownTracks.map(\.id))
    }

    func next(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        let similarTracks = try await seededRecommendations(
            accessToken: accessToken,
            musicService: musicService
        )
        let personalTracks = try await personalRecommendations(
            accessToken: accessToken,
            musicService: musicService
        )

        var fallback: [Track] = []
        if personalTracks.isEmpty && similarTracks.isEmpty {
            fallback = try await nextCommonMixPage(
                accessToken: accessToken,
                musicService: musicService
            )
        }

        let composed = SelenaRecommendationComposer.compose(
            seedTracks: seeds,
            personalRecommendations: personalTracks,
            similarRecommendations: similarTracks,
            fallbackMix: fallback
        ).filter { knownIDs.insert($0.id).inserted }

        if !composed.isEmpty {
            seeds = SelenaRecommendationComposer.seedTracks(
                history: [],
                recommendations: seeds + composed,
                loaded: []
            )
        }
        return composed
    }

    private func personalRecommendations(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        do {
            return try await musicService.recommendations(
                accessToken: accessToken
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

    private func seededRecommendations(
        accessToken: String,
        musicService: any MusicService
    ) async throws -> [Track] {
        guard !seeds.isEmpty else { return [] }
        var collected: [Track] = []
        let seedBatch = nextSeeds(count: 3)
        for seed in seedBatch {
            do {
                let tracks = try await musicService.recommendations(
                    seededBy: seed,
                    accessToken: accessToken,
                    shuffle: true
                )
                collected.append(contentsOf: tracks)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error == .unauthorized
                || error.isConnectivityFailure {
                throw error
            } catch {
                continue
            }
        }
        return collected
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
