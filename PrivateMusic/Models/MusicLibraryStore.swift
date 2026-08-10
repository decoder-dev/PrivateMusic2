import Foundation

@MainActor
final class MusicLibraryStore: ObservableObject {
    @Published private(set) var signatures = Set<String>()
    private var tracksBySignature: [String: Track] = [:]
    private var refreshGeneration = 0
    /// Tracks the user unliked since the last full walk. VK keeps serving
    /// them for a moment, so a page that folds in afterwards must not put
    /// the heart back.
    private var removedSignatures = Set<String>()

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
        // This walk is newer than every local edit that came before it, so
        // the server has the last word on what was removed.
        removedSignatures.removeAll()
    }

    /// Folds one loaded page into the index without dropping what the full
    /// walk already found. Медиатека shows the first pages of the same
    /// `audio.get` list, so replacing the index from there used to shrink a
    /// 1000-track index to 100 and blank the heart on everything below it.
    ///
    /// Unlike `replace(with:refreshID:)` a page carries no generation — it is
    /// additive, so a stale one cannot shrink anything. It can still arrive
    /// after the user unliked one of its tracks, which is what
    /// `removedSignatures` holds back.
    func include(_ tracks: [Track]) {
        var added = Set<String>()
        for track in tracks {
            let signature = Self.signature(track)
            guard !removedSignatures.contains(signature) else { continue }
            if tracksBySignature[signature] == nil {
                tracksBySignature[signature] = track
            }
            if !signatures.contains(signature) {
                added.insert(signature)
            }
        }
        guard !added.isEmpty else { return }
        signatures.formUnion(added)
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
        removedSignatures.remove(sourceSignature)
        removedSignatures.remove(storedSignature)
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
            removedSignatures.insert(alias)
        }
        signatures.remove(signature)
        removedSignatures.insert(signature)
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
