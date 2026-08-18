import Foundation

/// One artist candidate for the Home dynamic-artist section, scored from
/// real listening evidence.
struct ArtistAffinityCandidate: Identifiable, Equatable, Sendable {
    var id: String { artistKey }
    /// Normalized via `MixFeedbackPolicy.normalized` — the same key
    /// `MixFeedbackStore` bans against, so suppression and scoring agree
    /// on what "this artist" means without a second identity system.
    let artistKey: String
    let displayName: String
    let score: Double
    let evidenceTrackCount: Int
    let isLiked: Bool
    /// The strongest single reason behind the score, so the UI explains
    /// itself from what actually drove it rather than a raw number.
    let reason: Reason

    enum Reason: Equatable, Sendable {
        case likedAndPlayed
        case frequentRecently
        case multipleTracks
    }
}

/// Deterministic, explainable "does this listener seem to like this
/// artist" scoring — no ML, no remote calls, no hidden weights. Built
/// entirely from signals the app already tracks:
///
/// - confirmed listens in `ListeningHistoryStore` (a track only lands
///   there once `ListeningProgressPolicy` has counted it as actually
///   heard, which already excludes accidental taps and early skips);
/// - library membership, as a strong explicit positive;
/// - explicit suppression from `MixFeedbackStore`, reused as-is rather
///   than duplicating a second "hidden artist" list.
///
/// One accidental replay of a single track is evidence of a song, not an
/// artist — `minimumDistinctTracks` is what keeps that from ever
/// qualifying.
enum ArtistAffinityPolicy {
    /// History older than this contributes nothing — interest a listener
    /// has visibly moved on from should not keep surfacing.
    static let analysisWindow: TimeInterval = 30 * 24 * 60 * 60
    /// Half of a play's weight is gone after this long, so a burst of
    /// listening three weeks ago matters less than one from yesterday.
    static let recencyHalfLife: TimeInterval = 10 * 24 * 60 * 60
    static let minimumDistinctTracks = 2
    static let likeBoost = 1.5
    /// A candidate needs to clear this to appear at all...
    static let qualifyingScore = 1.3
    /// ...and can drop to this before losing a slot it already holds, so a
    /// score wobbling around the qualifying line does not flicker the
    /// section in and out on every track.
    static let retentionScore = 0.9

    private struct Evidence {
        var displayName: String
        var trackIDs: Set<String> = []
        var weightedRecency: Double = 0
    }

    static func candidates(
        history: [ListeningHistoryEntry],
        isLiked: (Track) -> Bool,
        bannedArtistKeys: Set<String>,
        now: Date = Date()
    ) -> [ArtistAffinityCandidate] {
        let cutoff = now.addingTimeInterval(-analysisWindow)
        let recent = history.filter { $0.playedAt >= cutoff }

        var evidence: [String: Evidence] = [:]
        var likedKeys: Set<String> = []

        for entry in recent {
            let age = max(0, now.timeIntervalSince(entry.playedAt))
            let weight = pow(0.5, age / recencyHalfLife)
            let liked = isLiked(entry.track)
            for name in ArtistCreditDisplay.components(entry.track.artist) {
                let key = MixFeedbackPolicy.normalized(name)
                guard !key.isEmpty, !bannedArtistKeys.contains(key) else {
                    continue
                }
                var record = evidence[key] ?? Evidence(displayName: name)
                record.trackIDs.insert(entry.track.id)
                record.weightedRecency += weight
                evidence[key] = record
                // Liked is per-artist, not per-track: N liked tracks by the
                // same artist must not compound the boost N times.
                if liked { likedKeys.insert(key) }
            }
        }

        return evidence.compactMap { key, record in
            guard record.trackIDs.count >= minimumDistinctTracks else {
                return nil
            }
            let liked = likedKeys.contains(key)
            let score = record.weightedRecency * (liked ? likeBoost : 1)
            guard score >= retentionScore else { return nil }
            let reason: ArtistAffinityCandidate.Reason = liked
                ? .likedAndPlayed
                : record.trackIDs.count >= 4
                    ? .frequentRecently
                    : .multipleTracks
            return ArtistAffinityCandidate(
                artistKey: key,
                displayName: record.displayName,
                score: score,
                evidenceTrackCount: record.trackIDs.count,
                isLiked: liked,
                reason: reason
            )
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.artistKey < rhs.artistKey
                : lhs.score > rhs.score
        }
    }

    /// Picks the one artist Home shows, applying the qualifying threshold
    /// and the "keep what's already shown" stickiness that keeps the
    /// section stable across tracks instead of reshuffling on every play.
    static func selectDynamicArtist(
        from candidates: [ArtistAffinityCandidate],
        previouslyShownKey: String?
    ) -> ArtistAffinityCandidate? {
        if let previouslyShownKey,
           let sticky = candidates.first(
               where: { $0.artistKey == previouslyShownKey }
           ),
           sticky.score >= retentionScore {
            return sticky
        }
        return candidates.first { $0.score >= qualifyingScore }
    }
}
