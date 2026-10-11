import Foundation

struct SavedLyricsRecord: Codable, Identifiable, Sendable {
    let track: Track
    let lyrics: Lyrics
    var id: String { track.id }
}

@MainActor
@Observable
final class SavedLyricsStore {
    private(set) var records: [SavedLyricsRecord] = []
    private let defaults: UserDefaults
    private var accountID: Int?
    private var key: String? { accountID.map { "lyrics.saved.v1.\($0)" } }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func configure(accountID: Int?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        records = key.flatMap { defaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([SavedLyricsRecord].self, from: $0) } ?? []
    }

    func save(_ lyrics: Lyrics, for track: Track) {
        guard let key, !lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lyrics.text.utf8.count < 150_000 else { return }
        // Signed stream URLs and VK access keys never belong in the lyric index.
        let safe = Track(trackID: track.trackID, ownerID: track.ownerID, title: track.title,
                         artist: track.artist, albumTitle: track.albumTitle, duration: track.duration,
                         streamURL: nil, artworkURL: track.artworkURL)
        records.removeAll { $0.id == track.id }
        records.insert(SavedLyricsRecord(track: safe, lyrics: lyrics), at: 0)
        records = Array(records.prefix(150))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    func lyrics(for track: Track) -> Lyrics? { records.first { $0.id == track.id }?.lyrics }

    func search(_ query: String) -> [SavedLyricsRecord] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, !words.isEmpty else { return [] }
        return records.filter { record in
            let text = "\(record.track.artist) \(record.track.title) \(record.lyrics.text)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
