import Foundation

enum TrackInformationText {
    static func formatted(_ track: Track) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [artist, title].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
