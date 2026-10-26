import Foundation

enum TrackInformationText {
    static func artworkInitials(_ track: Track) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = artist.isEmpty ? track.title : artist
        let initials = source.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)
        return initials.map { String($0).uppercased() }.joined()
    }

    static func formatted(_ track: Track) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [artist, title].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
