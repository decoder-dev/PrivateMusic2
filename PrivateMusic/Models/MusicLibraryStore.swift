import Foundation

@MainActor
final class MusicLibraryStore: ObservableObject {
    @Published private(set) var signatures = Set<String>()
    private var tracksBySignature: [String: Track] = [:]
    private var refreshGeneration = 0

    /// Callers that fetch a full remote library page must obtain this ID and
    /// pass it back to `replace(with:refreshID:)`. Local add/remove and newer
    /// refreshes bump the generation so a slower empty/failed load cannot
    /// wipe a newer successful index.
    func beginRefresh() -> Int {
        refreshGeneration += 1
        return refreshGeneration
    }

    func replace(with tracks: [Track], refreshID: Int) {
        guard refreshID == refreshGeneration else { return }
        signatures = Set(tracks.map(Self.signature))
        tracksBySignature = Dictionary(
            tracks.map { (Self.signature($0), $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    func contains(_ track: Track) -> Bool {
        signatures.contains(Self.signature(track))
    }

    func isLiked(_ track: Track, currentUserID: Int?) -> Bool {
        contains(track)
            || (currentUserID != nil && track.ownerID == currentUserID)
    }

    func markAdded(source: Track, stored: Track) {
        refreshGeneration += 1
        let sourceSignature = Self.signature(source)
        let storedSignature = Self.signature(stored)
        signatures.insert(sourceSignature)
        signatures.insert(storedSignature)
        tracksBySignature[sourceSignature] = stored
        tracksBySignature[storedSignature] = stored
    }

    func markRemoved(_ track: Track) {
        refreshGeneration += 1
        let signature = Self.signature(track)
        let storedID = tracksBySignature[signature]?.id ?? track.id
        let aliases = tracksBySignature.compactMap { key, stored in
            key == signature || stored.id == storedID ? key : nil
        }
        for alias in aliases {
            signatures.remove(alias)
            tracksBySignature.removeValue(forKey: alias)
        }
        signatures.remove(signature)
    }

    func storedTrack(for track: Track) -> Track? {
        tracksBySignature[Self.signature(track)]
    }

    private static func signature(_ track: Track) -> String {
        let title = normalized(track.title)
        let artist = normalized(track.artist)
        let duration = Int(track.duration.rounded())
        return "\(artist)|\(title)|\(duration)"
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
