import Foundation

/// Gates whether mix-radio should pull a fresh VK recommendation page.
/// Background queue appends must stay local — a server refill calls
/// `replaceUpcoming` and would wipe continuation-filled tracks.
enum MixRadioRefillPolicy {
    static func shouldRefillFromServer(
        triggeredByAppend: Bool,
        mode: MixRadioMode
    ) -> Bool {
        guard !triggeredByAppend else { return false }
        switch mode {
        case .closerToSeed, .moreNovel:
            return true
        case .balanced:
            return false
        }
    }

    /// Stale async refills must not rewrite the queue after the user has
    /// already moved on (new play, skip, mode change, non-mix source).
    static func shouldApplyRefill(
        taskGeneration: Int,
        currentGeneration: Int,
        expectedMode: MixRadioMode,
        currentMode: MixRadioMode,
        expectedSeedID: String,
        currentTrackID: String?,
        isMixQueue: Bool
    ) -> Bool {
        guard taskGeneration == currentGeneration,
              isMixQueue,
              expectedMode == currentMode,
              let currentTrackID,
              currentTrackID == expectedSeedID else {
            return false
        }
        return true
    }
}

/// Keeps user "Play Next" pins at the front of the unplayed suffix when a
/// server radio refill replaces the rest of the upcoming queue.
enum MixRadioUpcomingMergePolicy {
    static func merge(
        head: [Track],
        existingUpcoming: [Track],
        replacement: [Track],
        pinnedIDs: Set<String>,
        limit: Int
    ) -> [Track] {
        var known = Set(head.map(\.id))
        var upcoming: [Track] = []
        for track in existingUpcoming where pinnedIDs.contains(track.id) {
            guard known.insert(track.id).inserted else { continue }
            upcoming.append(track)
            if upcoming.count >= limit { return head + upcoming }
        }
        for track in replacement {
            guard known.insert(track.id).inserted else { continue }
            upcoming.append(track)
            if upcoming.count >= limit { break }
        }
        return head + upcoming
    }
}
