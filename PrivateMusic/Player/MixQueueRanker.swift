import Foundation

enum MixRadioMode: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case closerToSeed
    case moreNovel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return L10n.text("balanced")
        case .closerToSeed:
            return L10n.text("closer_to_track")
        case .moreNovel:
            return L10n.text("more_novelty")
        }
    }

    /// Segmented pickers clip the full titles on compact widths.
    var compactTitle: String {
        switch self {
        case .balanced:
            return L10n.text("balanced")
        case .closerToSeed:
            return L10n.text("closer")
        case .moreNovel:
            return L10n.text("novelty")
        }
    }

    var caption: String {
        switch self {
        case .balanced:
            return L10n.text(
                "shuffles_loaded_tracks_and_keeps_artists_spaced_out"
            )
        case .closerToSeed:
            return L10n.text(
                "prioritizes_music_closer_to_the_current_track_and_recent_history"
            )
        case .moreNovel:
            return L10n.text(
                "adds_more_new_artists_and_fewer_repeats_from_recent_listening"
            )
        }
    }
}

enum MixQueueRanker {
    /// Reorders only the unplayed suffix. Preserves played prefix + current.
    ///
    /// Ranking is deterministic for a given queue + mode so background
    /// refreshes / accidental double-applies do not reshuffle mid-listen.
    static func rerank(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String> = []
    ) -> [Track] {
        var rng = StableMixRNG(
            seed: stableSeed(
                queue: queue,
                currentIndex: currentIndex,
                mode: mode
            )
        )
        return rerank(
            queue: queue,
            currentIndex: currentIndex,
            seed: seed,
            mode: mode,
            historyArtists: historyArtists,
            rng: &rng
        )
    }

    /// Stable seed so the same upcoming set ranks the same way.
    ///
    /// The FNV-1a rounds run in PrivateMusicCore.c: the Swift version walked
    /// every track id one byte at a time through a closure, which is the whole
    /// queue's worth of UTF-8 on every rerank.
    ///
    /// The native rounds also use the real FNV-1a prime; the Swift constant had
    /// an extra zero. Seeds therefore shift once, which only changes which
    /// deterministic order a queue lands on — the seed is never persisted and
    /// the same queue still always ranks the same way.
    static func stableSeed(
        queue: [Track],
        currentIndex: Int,
        mode: MixRadioMode
    ) -> UInt64 {
        var hash = pm_hash_fnv1a64_basis
        for (index, track) in queue.enumerated() {
            hash = pm_hash_fnv1a64_value(hash, UInt64(index &+ 1))
            hash = hashingBytes(of: track.id, into: hash)
        }
        hash = pm_hash_fnv1a64_value(hash, UInt64(currentIndex &+ 1))
        hash = hashingBytes(of: mode.rawValue, into: hash)
        return hash == 0 ? 0x9e37_79b9_7f4a_7c15 : hash
    }

    private static func hashingBytes(
        of text: String,
        into hash: UInt64
    ) -> UInt64 {
        var text = text
        return text.withUTF8 { buffer in
            pm_hash_fnv1a64_bytes(
                hash,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
    }

    /// Identity of a normalized artist / album name in the ranking hash space.
    /// Empty names hash to 0, which the C scorer reads as "no artist".
    private static func identity(of normalizedValue: String) -> UInt64 {
        var value = normalizedValue
        return value.withUTF8 { buffer in
            pm_text_identity_hash(buffer.baseAddress, Int32(buffer.count))
        }
    }

    static func rerank<G: RandomNumberGenerator>(
        queue: [Track],
        currentIndex: Int,
        seed: Track,
        mode: MixRadioMode,
        historyArtists: Set<String> = [],
        rng: inout G
    ) -> [Track] {
        guard queue.indices.contains(currentIndex) else { return queue }
        let head = Array(queue.prefix(currentIndex + 1))
        let remaining = Array(queue.suffix(from: currentIndex + 1))
        guard remaining.count > 1 else { return queue }

        let seedArtist = normalized(seed.artist)
        let seedAlbum = seed.albumTitle.map(normalized) ?? ""
        let history = Set(historyArtists.map(normalized))

        let built: [Track]
        switch mode {
        case .balanced:
            built = diversifyBalanced(remaining, rng: &rng)
        case .closerToSeed, .moreNovel:
            built = greedilyRank(
                remaining,
                seedArtist: seedArtist,
                seedAlbum: seedAlbum,
                history: history,
                head: head,
                mode: mode,
                rng: &rng
            )
        }

        return head + built
    }

    /// Shuffle then repair adjacent same-artist pairs so VK clusters do
    /// not survive as a no-op «Баланс» ordering.
    ///
    /// Artists are folded once into hash identities up front; the repair sweep
    /// then compares integers, where it used to re-fold neighbouring names on
    /// every step and again for every candidate it scanned for a swap.
    private static func diversifyBalanced<G: RandomNumberGenerator>(
        _ upcoming: [Track],
        rng: inout G
    ) -> [Track] {
        var items = upcoming
        items.shuffle(using: &rng)
        guard items.count > 1 else { return items }

        var artists = items.map { identity(of: normalized($0.artist)) }
        for index in 1..<items.count {
            let prev = artists[index - 1]
            guard prev != 0, prev == artists[index] else { continue }
            if let swapIndex = (index + 1..<items.count).first(where: {
                artists[$0] != prev
            }) {
                items.swapAt(index, swapIndex)
                artists.swapAt(index, swapIndex)
            }
        }
        return items
    }

    /// Greedy selection runs in PrivateMusicCore.c (`pm_mix_select_best`).
    /// Every artist and album is folded and hashed once here instead of once
    /// per candidate per pick, so the O(n²) sweep compares 64-bit identities
    /// rather than re-normalizing strings.
    private static func greedilyRank<G: RandomNumberGenerator>(
        _ upcoming: [Track],
        seedArtist: String,
        seedAlbum: String,
        history: Set<String>,
        head: [Track],
        mode: MixRadioMode,
        rng: inout G
    ) -> [Track] {
        var remaining = upcoming
        var candidates = upcoming.map { track in
            PMMixCandidate(
                artist_hash: identity(of: normalized(track.artist)),
                album_hash: identity(
                    of: track.albumTitle.map(normalized) ?? ""
                )
            )
        }
        var recentArtists = head.suffix(4).map {
            identity(of: normalized($0.artist))
        }
        let historyArtists = Set(history.map(identity(of:))).sorted()
        let seedArtistHash = identity(of: seedArtist)
        let seedAlbumHash = identity(of: seedAlbum)
        let nativeMode: Int32 = mode == .closerToSeed
            ? Int32(PM_MIX_MODE_CLOSER_TO_SEED)
            : Int32(PM_MIX_MODE_MORE_NOVEL)
        // Tie-breaker range per mode, drawn here so the caller's generator
        // still owns the sequence and ranking stays reproducible.
        let jitterRange: Double = mode == .closerToSeed ? 3 : 10
        var jitter = [Double](repeating: 0, count: remaining.count)
        var built: [Track] = []
        built.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            let count = remaining.count
            for index in 0..<count {
                jitter[index] = Double.random(in: 0..<jitterRange, using: &rng)
            }
            let bestIndex = selectBest(
                candidates: candidates,
                jitter: jitter,
                count: count,
                mode: nativeMode,
                seedArtist: seedArtistHash,
                seedAlbum: seedAlbumHash,
                history: historyArtists,
                recent: recentArtists
            )
            let picked = remaining.remove(at: bestIndex)
            let pickedArtist = candidates.remove(at: bestIndex).artist_hash
            built.append(picked)
            recentArtists.append(pickedArtist)
            if recentArtists.count > 5 {
                recentArtists.removeFirst(recentArtists.count - 5)
            }
        }
        return built
    }

    private static func selectBest(
        candidates: [PMMixCandidate],
        jitter: [Double],
        count: Int,
        mode: Int32,
        seedArtist: UInt64,
        seedAlbum: UInt64,
        history: [UInt64],
        recent: [UInt64]
    ) -> Int {
        history.withUnsafeBufferPointer { historyBuffer in
            recent.withUnsafeBufferPointer { recentBuffer in
                candidates.withUnsafeBufferPointer { candidateBuffer in
                    jitter.withUnsafeBufferPointer { jitterBuffer in
                        var context = PMMixRankContext(
                            mode: mode,
                            seed_artist_hash: seedArtist,
                            seed_album_hash: seedAlbum,
                            history_hashes: historyBuffer.baseAddress,
                            history_count: Int32(historyBuffer.count)
                        )
                        return Int(
                            pm_mix_select_best(
                                candidateBuffer.baseAddress,
                                jitterBuffer.baseAddress,
                                Int32(count),
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

    private static func normalized(_ value: String) -> String {
        var value = value
        return value.withUTF8 { input -> String in
            guard let base = input.baseAddress else { return "" }
            return withUnsafeTemporaryAllocation(
                of: UInt8.self,
                capacity: input.count
            ) { scratch -> String in
                guard let output = scratch.baseAddress else {
                    return foundationNormalized(value)
                }
                let written = pm_text_normalize_identity(
                    base,
                    Int32(input.count),
                    output,
                    Int32(input.count)
                )
                guard written >= 0 else {
                    return foundationNormalized(value)
                }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: output,
                        count: Int(written)
                    ),
                    as: UTF8.self
                )
            }
        }
    }

    private static func foundationNormalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Deterministic RNG so mix ranking is stable for the same queue snapshot.
struct StableMixRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
