import Foundation

@MainActor
final class MusicLibraryStore: ObservableObject {
    @Published private(set) var signatures = Set<String>()

    func replace(with tracks: [Track]) {
        signatures = Set(tracks.map(Self.signature))
    }

    func contains(_ track: Track) -> Bool {
        signatures.contains(Self.signature(track))
    }

    func markAdded(source: Track, stored: Track) {
        signatures.insert(Self.signature(source))
        signatures.insert(Self.signature(stored))
    }

    func markRemoved(_ track: Track) {
        signatures.remove(Self.signature(track))
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
