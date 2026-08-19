import Foundation

/// How often each artist has already been put in front of the listener
/// during this run of the app.
///
/// Deliberately **not** persisted. The counts exist to stop one artist
/// dominating a sitting, and a listening session is the window where that
/// matters — after a relaunch, hearing a favourite again is the point of a
/// personal mix, not a failure. Carrying lifetime counts forward would do
/// the opposite: `log(totalPulls)` keeps growing, so the artists someone
/// plays most would be pushed down hardest, month after month.
struct SelenaExposure: Equatable, Sendable {
    private(set) var pullsByArtist: [String: Int] = [:]
    private(set) var totalPulls = 0

    init() {}

    init(pullsByArtist: [String: Int], totalPulls: Int) {
        self.pullsByArtist = pullsByArtist
        self.totalPulls = totalPulls
    }

    func pulls(forArtistKey key: String) -> Int {
        pullsByArtist[key] ?? 0
    }

    mutating func record(_ tracks: [Track]) {
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty else { continue }
            pullsByArtist[key, default: 0] += 1
            totalPulls += 1
        }
    }

    mutating func reset() {
        self = SelenaExposure()
    }
}

/// Exploration for the personal mix ("Selena"), so a queue built from the
/// listener's own history does not collapse onto the same three artists.
///
/// The shape is UCB-ish: an artist the listener has seen less this session
/// gets a bigger bonus, by `sqrt(log(N) / n)`. It is not a real bandit —
/// nothing here observes a reward — which is exactly why it lives behind a
/// named policy with tests rather than inside a view.
enum SelenaBanditPolicy {
    /// How loudly exploration argues against the queue's original order.
    /// Small on purpose: the incoming order already reflects the
    /// listener's taste, and this only breaks up clumps.
    static let explorationWeight = 0.45

    /// The exploration bonus for an artist seen `pulls` times out of
    /// `totalPulls`. Falls as an artist is used, so unheard artists rise.
    static func explorationBonus(pulls: Int, totalPulls: Int) -> Double {
        let total = Double(max(1, totalPulls))
        return (log(total + 1.0) / (Double(max(0, pulls)) + 1.0)).squareRoot()
    }

    static func rerank(
        _ tracks: [Track],
        exposure: SelenaExposure,
        bannedArtists: Set<String>
    ) -> [Track] {
        // A ban is a removal, not a demotion. The queue reaching this
        // point is normally already filtered, but a listener can ban an
        // artist after the queue was cached — and then "не нравится"
        // still has to mean the artist stops playing, not that they slide
        // a few rows down.
        let allowed = tracks.filter { track in
            let key = MixFeedbackPolicy.normalized(track.artist)
            return key.isEmpty || !bannedArtists.contains(key)
        }
        guard allowed.count > 1 else { return allowed }

        let ordered = allowed
            .enumerated()
            .map { index, track -> (track: Track, score: Double, index: Int) in
                let key = MixFeedbackPolicy.normalized(track.artist)
                let bonus = explorationBonus(
                    pulls: exposure.pulls(forArtistKey: key),
                    totalPulls: exposure.totalPulls
                )
                return (track, explorationWeight * bonus, index)
            }
            .sorted {
                // Ties keep the incoming order, so the same queue always
                // reranks the same way.
                $0.score == $1.score
                    ? $0.index < $1.index
                    : $0.score > $1.score
            }
            .map(\.track)

        return breakingUpRuns(ordered)
    }

    /// Pushes a repeated artist back one place at a time so the queue does
    /// not read as three tracks by the same person in a row.
    ///
    /// One forward pass, so this thins runs rather than guaranteeing none:
    /// a queue with nothing else left to swap in keeps its run, and that
    /// is the honest outcome — inventing variety that the tracks do not
    /// contain would mean dropping tracks.
    static func breakingUpRuns(_ tracks: [Track]) -> [Track] {
        guard tracks.count > 1 else { return tracks }
        var result = tracks
        for index in 1..<result.count {
            let previous = MixFeedbackPolicy.normalized(result[index - 1].artist)
            guard !previous.isEmpty else { continue }
            guard MixFeedbackPolicy.normalized(result[index].artist) == previous
            else { continue }
            let candidate = (index + 1..<result.count).first {
                MixFeedbackPolicy.normalized(result[$0].artist) != previous
            }
            guard let candidate else { continue }
            result.swapAt(index, candidate)
        }
        return result
    }
}
