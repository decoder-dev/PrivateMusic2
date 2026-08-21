import Foundation

/// Per-session explore/exploit over Selena content sources (personal /
/// similar / seed / fallback). Thompson-style Beta posteriors with
/// rewards from real listens and skips (not compose dedup alone).
struct SelenaSourceBandit: Equatable, Sendable {
    enum Arm: String, CaseIterable, Sendable {
        case personal
        case similar
        case seed
        case fallback
    }

    /// α, β for each arm. Start mildly optimistic so cold sessions still
    /// try every source.
    private(set) var alpha: [Arm: Double]
    private(set) var beta: [Arm: Double]

    init() {
        var a: [Arm: Double] = [:]
        var b: [Arm: Double] = [:]
        for arm in Arm.allCases {
            a[arm] = 2
            b[arm] = 2
        }
        self.alpha = a
        self.beta = b
    }

    mutating func reward(_ arm: Arm, success: Bool) {
        if success {
            alpha[arm, default: 2] += 1
        } else {
            beta[arm, default: 2] += 1
        }
    }

    /// After a compose round: arms that contributed kept tracks get a
    /// success; arms that only produced duplicates / drops get a miss.
    mutating func observeCompose(
        sources: [String: SelenaComposeSource],
        keptIDs: Set<String>
    ) {
        var kept = Set<Arm>()
        var dropped = Set<Arm>()
        for (id, source) in sources {
            if keptIDs.contains(id) {
                kept.insert(source.arm)
            } else {
                dropped.insert(source.arm)
            }
        }
        for arm in Arm.allCases {
            if kept.contains(arm) {
                reward(arm, success: true)
            } else if dropped.contains(arm) {
                reward(arm, success: false)
            }
        }
    }

    /// Deterministic draw from current posteriors (mean of Beta) so the
    /// same session evidence always yields the same compose bias — tests
    /// and accidental double-applies stay stable. Exploration still moves
    /// as rewards accrue.
    func composeBias(
        diversity: SelenaDiversityPreference
    ) -> (personal: Int, similar: Int, seedEvery: Int) {
        let base = SelenaWavePolicy.composeBias(diversity: diversity)
        let personalScore = mean(.personal)
        let similarScore = mean(.similar)
        let seedScore = mean(.seed)

        var personal = base.personal
        var similar = base.similar
        var seedEvery = base.seedEvery

        // Nudge fixed diversity bias by which sources this session rewarded.
        if personalScore > similarScore + 0.08 {
            personal = min(3, personal + 1)
            similar = max(1, similar)
        } else if similarScore > personalScore + 0.08 {
            similar = min(3, similar + 1)
            personal = max(1, personal)
        }
        if seedScore < 0.4 {
            seedEvery = min(8, seedEvery + 2)
        } else if seedScore > 0.6 {
            seedEvery = max(3, seedEvery - 1)
        }
        return (personal, similar, seedEvery)
    }

    private func mean(_ arm: Arm) -> Double {
        let a = alpha[arm] ?? 2
        let b = beta[arm] ?? 2
        return a / (a + b)
    }
}

/// Tags a composed track with the Selena source arm that contributed it,
/// so session rewards can update the source bandit.
enum SelenaComposeSource: Equatable, Sendable {
    case personal
    case similar
    case seed
    case fallback

    var arm: SelenaSourceBandit.Arm {
        switch self {
        case .personal: return .personal
        case .similar: return .similar
        case .seed: return .seed
        case .fallback: return .fallback
        }
    }
}
