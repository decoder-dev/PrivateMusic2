import Foundation

@MainActor
final class MusicLibraryStore: ObservableObject {
    @Published private(set) var signatures = Set<String>()
    private var tracksBySignature: [String: Track] = [:]

    func replace(with tracks: [Track]) {
        signatures = Set(tracks.map(Self.signature))
        tracksBySignature = Dictionary(
            tracks.map { (Self.signature($0), $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    func contains(_ track: Track) -> Bool {
        signatures.contains(Self.signature(track))
    }

    func markAdded(source: Track, stored: Track) {
        let sourceSignature = Self.signature(source)
        let storedSignature = Self.signature(stored)
        signatures.insert(sourceSignature)
        signatures.insert(storedSignature)
        tracksBySignature[sourceSignature] = stored
        tracksBySignature[storedSignature] = stored
    }

    func markRemoved(_ track: Track) {
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
