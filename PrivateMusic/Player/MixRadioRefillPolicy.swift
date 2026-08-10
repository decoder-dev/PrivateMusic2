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
}
