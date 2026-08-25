import Foundation

/// How often each artist has already been put in front of the listener
/// during this run of the app.
///
/// These are impressions, not plays: a queue of fifty tracks counts fifty,
/// whether the listener heard three of them or all of them. That is the
/// honest reading of the signal — it answers "how much of this queue have
/// I already given to this artist", which is exactly what the spacing
/// decision needs, and nothing more.
///
/// Deliberately **not** persisted. The counts exist to stop one artist
/// dominating a sitting, and a listening session is the window where that
/// matters — after a relaunch, hearing a favourite again is the point of a
/// personal mix, not a failure. Carrying lifetime counts forward would do
/// the opposite: the artists someone plays most would be pushed down
/// hardest, month after month.
struct SelenaExposure: Equatable, Sendable {
    private(set) var impressionsByArtist: [String: Int] = [:]
    private(set) var totalImpressions = 0

    init() {}

    init(impressionsByArtist: [String: Int], totalImpressions: Int) {
        self.impressionsByArtist = impressionsByArtist
        self.totalImpressions = totalImpressions
    }

    func impressions(forArtistKey key: String) -> Int {
        impressionsByArtist[key] ?? 0
    }

    mutating func record(_ tracks: [Track]) {
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty else { continue }
            impressionsByArtist[key, default: 0] += 1
            totalImpressions += 1
        }
    }

    mutating func reset() {
        self = SelenaExposure()
    }
}

/// Orders the personal mix ("Selena") from what the listener has actually
/// shown us, balancing two things that pull against each other:
///
/// - **familiarity** — how much evidence there is that this listener likes
///   this artist, reused from `ArtistAffinityPolicy` rather than invented
///   here, so Home's "What's Next" and the mix agree on who a favourite
///   is;
/// - **novelty** — how little of this session's queue has already gone to
///   that artist.
///
/// A personal mix should lean familiar; novelty is what stops it becoming
/// the same six artists on a loop. The weights say so out loud.
///
/// This replaced a UCB-shaped formula that could not work as one. A bandit
/// needs a reward, and there was none — the exploitation term was a
/// constant — so the score reduced to `sqrt(log(N) / (n + 1))`, where the
/// `log(N)` is a factor common to every candidate and therefore cannot
/// change their order. What was left ranked purely by "least shown", which
/// for a queue built from someone's own history pushes their favourites
/// *down*. It also gave every track by one artist the same score, so the
/// sort produced exactly the runs that a repair pass then had to undo.
enum SelenaBanditPolicy {
    /// Weights sum to 1 so a score is always 0...1 and can be reasoned
    /// about directly.
    static let familiarityWeight = 0.65
    static let noveltyWeight = 0.35

    /// The affinity score at which an artist counts as half familiar.
    /// Tied to the bar Home uses to call an artist a favourite at all, so
    /// the two features cannot drift into disagreeing.
    static let affinityMidpoint = ArtistAffinityPolicy.qualifyingScore

    /// How many tracks must separate two by the same artist, when the
    /// pool allows it.
    static let artistSpacing = 3

    /// Affinity is unbounded — it grows with every confirmed play — so it
    /// is squashed into 0...1 rather than normalized against whatever
    /// happens to be in this queue. A queue of unknown artists must not
    /// promote one of them to "favourite" just by being the best of a bad
    /// lot.
    static func familiarity(affinity: Double) -> Double {
        guard affinity > 0 else { return 0 }
        return affinity / (affinity + affinityMidpoint)
    }

    /// 1 for an artist this session has not shown yet, falling as their
    /// share of the queue grows.
    /// Soft mood boost folded into the bandit score (0...1). PreferMood
    /// alone lost to continuous familiarity/novelty floats on almost every
    /// tie-break, so mood must participate in the primary score.
    static let moodWeight = 0.18

    static func novelty(impressions: Int) -> Double {
        1 / (Double(max(0, impressions)) + 1).squareRoot()
    }

    static func score(affinity: Double, impressions: Int) -> Double {
        familiarityWeight * familiarity(affinity: affinity)
            + noveltyWeight * novelty(impressions: impressions)
    }

    static func moodBoost(_ score: Int) -> Double {
        guard score > 0 else { return 0 }
        // Cap so a single keyword match cannot dominate familiarity.
        return min(1, Double(score) / 2)
    }

    /// - Parameters:
    ///   - affinityByArtistKey: `ArtistAffinityPolicy` scores keyed the way
    ///     `MixFeedbackPolicy.normalized` keys them. Absent means no
    ///     evidence, which scores as unfamiliar rather than as disliked.
    ///   - moodScoresByTrackID: optional soft moodEnergy boosts from
    ///     `SelenaWavePolicy.moodScore` — 0 for unmatched tracks.
    static func rerank(
        _ tracks: [Track],
        affinityByArtistKey: [String: Double],
        exposure: SelenaExposure,
        bannedArtists: Set<String>,
        familiarityWeight: Double = familiarityWeight,
        noveltyWeight: Double = noveltyWeight,
        artistSpacing spacing: Int = artistSpacing,
        moodScoresByTrackID: [String: Int] = [:],
        moodWeight: Double = moodWeight
    ) -> [Track] {
        // A ban is a removal, not a demotion. The queue reaching this
        // point is normally already filtered, but a listener can ban an
        // artist while a queue is cached — and then "не нравится" still
        // has to mean the artist stops playing, not that they slide a few
        // rows down.
        let allowed = tracks.filter { track in
            let key = MixFeedbackPolicy.normalized(track.artist)
            return key.isEmpty || !bannedArtists.contains(key)
        }
        guard allowed.count > 1 else { return allowed }

        let fam = max(0, familiarityWeight)
        let nov = max(0, noveltyWeight)
        let moodW = max(0, moodWeight)
        let weightSum = fam + nov + moodW
        let famNorm = weightSum > 0 ? fam / weightSum : Self.familiarityWeight
        let novNorm = weightSum > 0 ? nov / weightSum : Self.noveltyWeight
        let moodNorm = weightSum > 0 ? moodW / weightSum : 0
        let gap = max(1, spacing)

        let candidates = allowed.enumerated().map { index, track in
            let key = MixFeedbackPolicy.normalized(track.artist)
            let raw = famNorm * familiarity(
                affinity: affinity(for: track, in: affinityByArtistKey)
            ) + novNorm * novelty(
                impressions: exposure.impressions(forArtistKey: key)
            ) + moodNorm * moodBoost(moodScoresByTrackID[track.id] ?? 0)
            return Candidate(
                track: track,
                artistKey: key,
                score: raw,
                index: index
            )
        }
        return spacedOrder(candidates, artistSpacing: gap)
    }

    /// Affinity is stored per credit component ("A", "B"); tracks often carry
    /// the joined VK string ("A, B"). Take the best component match so
    /// collaborations are not scored as strangers.
    private static func affinity(
        for track: Track,
        in affinityByArtistKey: [String: Double]
    ) -> Double {
        let components = ArtistCreditDisplay.components(track.artist)
        let keys = components.isEmpty
            ? [MixFeedbackPolicy.normalized(track.artist)]
            : components.map(MixFeedbackPolicy.normalized)
        return keys.compactMap { key -> Double? in
            guard !key.isEmpty else { return nil }
            return affinityByArtistKey[key]
        }
        .max() ?? 0
    }

    private struct Candidate {
        let track: Track
        let artistKey: String
        let score: Double
        let index: Int
    }

    /// Takes the best track whose artist has not appeared in the last
    /// `artistSpacing` picks. When no track can satisfy that — the pool
    /// has run down to artists already used — it takes the one whose
    /// artist was heard **longest ago** rather than simply the best
    /// scoring one, which is what keeps the tail of a queue alternating
    /// instead of collapsing into a block of whoever scored highest.
    ///
    /// Spacing is a constraint on the ordering, not a filter — a queue
    /// with one artist left comes back whole and clumped rather than
    /// short. Dropping music to look varied is the worse trade, and the
    /// listener asked for a queue, not a demonstration.
    private static func spacedOrder(
        _ candidates: [Candidate],
        artistSpacing gap: Int = artistSpacing
    ) -> [Track] {
        var remaining = candidates.sorted {
            // Ties keep the incoming order, so the same queue and the same
            // evidence always give the same result.
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        var result: [Track] = []
        result.reserveCapacity(remaining.count)
        var recentKeys: [String] = []
        var lastPositionByKey: [String: Int] = [:]
        let spacing = max(1, gap)

        while !remaining.isEmpty {
            let pick = remaining.firstIndex {
                $0.artistKey.isEmpty || !recentKeys.contains($0.artistKey)
            } ?? leastRecentlyUsed(
                in: remaining,
                at: result.count,
                lastPositionByKey
            )
            let chosen = remaining.remove(at: pick)
            result.append(chosen.track)
            if !chosen.artistKey.isEmpty {
                lastPositionByKey[chosen.artistKey] = result.count - 1
                recentKeys.append(chosen.artistKey)
                if recentKeys.count > spacing {
                    recentKeys.removeFirst()
                }
            }
        }
        return result
    }

    /// Index of the candidate whose artist has been away the longest,
    /// preferring the better score and then the incoming order when two
    /// have been away equally long.
    private static func leastRecentlyUsed(
        in remaining: [Candidate],
        at position: Int,
        _ lastPositionByKey: [String: Int]
    ) -> Int {
        var best = 0
        var bestDistance = Int.min
        var bestScore = -Double.infinity
        for (offset, candidate) in remaining.enumerated() {
            let last = lastPositionByKey[candidate.artistKey]
            // Never used this run: as far away as it gets.
            let distance = last.map { position - $0 } ?? Int.max
            let better = distance > bestDistance
                || (distance == bestDistance && candidate.score > bestScore)
            guard better else { continue }
            best = offset
            bestDistance = distance
            bestScore = candidate.score
        }
        return best
    }
}
