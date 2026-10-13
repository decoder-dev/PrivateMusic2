import Foundation

/// Turns text pasted or exported from another service into a list of
/// (artist, title) pairs, and decides which VK search result is the same song.
/// Pure logic: the screen only drives it.
enum PlaylistImportParser {
    struct Item: Equatable, Identifiable, Sendable {
        let artist: String
        let title: String
        var id: String { "\(artist)\u{1F}\(title)" }
        var displayName: String {
            artist.isEmpty ? title : "\(artist) — \(title)"
        }
    }

    /// Upper bound on one import: a VK playlist holds at most a few
    /// thousand tracks and every item costs a search request.
    static let maximumItems = 500

    private static let titleHeaders: Set<String> = [
        "track name", "trackname", "track", "title", "song", "song name",
        "name", "название", "трек", "песня", "название трека"
    ]
    private static let artistHeaders: Set<String> = [
        "artist name(s)", "artist names", "artist name", "artist", "artists",
        "performer", "исполнитель", "исполнители", "артист", "артисты"
    ]
    private static let separators = [" — ", " – ", " - ", "\t"]

    static func parse(_ text: String) -> [Item] {
        let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let items = csvItems(in: cleaned) ?? lineItems(in: cleaned)
        var seen = Set<String>()
        var result: [Item] = []
        for item in items where seen.insert(item.id.lowercased()).inserted {
            result.append(item)
            if result.count >= maximumItems { break }
        }
        return result
    }

    // MARK: Plain lines

    /// "Artist - Title" per line; a line without a separator is a title.
    private static func lineItems(in text: String) -> [Item] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            // A leading "1. " or "12) " from a numbered list is not part of it.
            let stripped = line.replacingOccurrences(
                of: #"^\d{1,4}[.)]\s+"#,
                with: "",
                options: .regularExpression
            )
            for separator in separators {
                if let range = stripped.range(of: separator) {
                    let artist = clean(String(stripped[..<range.lowerBound]))
                    let title = clean(String(stripped[range.upperBound...]))
                    if !title.isEmpty { return Item(artist: artist, title: title) }
                }
            }
            let title = clean(stripped)
            return title.isEmpty ? nil : Item(artist: "", title: title)
        }
    }

    // MARK: CSV

    /// Returns nil when the text does not start with a recognisable header,
    /// so ordinary lines containing commas are not misread as a table.
    private static func csvItems(in text: String) -> [Item]? {
        let rows = parseCSV(text)
        guard let header = rows.first, header.count >= 2 else { return nil }
        let names = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let titleColumn = names.firstIndex(where: titleHeaders.contains),
              let artistColumn = names.firstIndex(where: artistHeaders.contains),
              titleColumn != artistColumn else { return nil }
        return rows.dropFirst().compactMap { row in
            guard row.indices.contains(titleColumn), row.indices.contains(artistColumn) else {
                return nil
            }
            let title = clean(row[titleColumn])
            guard !title.isEmpty else { return nil }
            // Spotify exports several artists as "A;B"; the first is enough
            // to find the song and keeps the query short.
            let artists = row[artistColumn]
                .split(separator: ";")
                .map { clean(String($0)) }
                .filter { !$0.isEmpty }
            return Item(artist: artists.joined(separator: ", "), title: title)
        }
    }

    /// RFC 4180: quoted fields, doubled quotes, separators and line breaks
    /// inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func finishField() {
            row.append(field)
            field = ""
        }
        func finishRow() {
            finishField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case ",":
                    finishField()
                case "\n", "\r\n", "\r":
                    finishRow()
                default:
                    field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }

    private static func clean(_ value: String) -> String {
        var result = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // Quotes that wrap the whole value belong to the export format, not
        // to the name ("Say \"Hi\"" keeps its own).
        for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("«", "»")]
        where result.count >= 2 && result.hasPrefix(open) && result.hasSuffix(close) {
            result = String(result.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            break
        }
        return result
    }
}

enum PlaylistImportMatcher {
    struct Match: Equatable, Sendable {
        let track: Track
        /// 0...1, how sure the match is.
        let confidence: Double
        /// Below this the screen leaves the row switched off until the user
        /// looks at it.
        var isConfident: Bool { confidence >= PlaylistImportMatcher.confidentThreshold }
    }

    static let acceptanceThreshold = 0.72
    static let confidentThreshold = 0.86

    /// Search query for one item: lead artist and the title without brackets
    /// and "feat." tails.
    static func query(for item: PlaylistImportParser.Item) -> String {
        GeniusMatcher.searchQuery(artist: item.artist, title: item.title)
    }

    static func best(
        for item: PlaylistImportParser.Item,
        in candidates: [Track]
    ) -> Match? {
        var best: Match?
        for track in candidates {
            let value = confidence(item: item, track: track)
            guard value >= acceptanceThreshold else { continue }
            if best == nil || value > best!.confidence {
                best = Match(track: track, confidence: value)
            }
        }
        return best
    }

    static func confidence(
        item: PlaylistImportParser.Item,
        track: Track
    ) -> Double {
        let wantedTitle = GeniusMatcher.key(GeniusMatcher.displayTitle(item.title))
        let foundTitle = GeniusMatcher.key(GeniusMatcher.displayTitle(track.title))
        guard !wantedTitle.isEmpty, !foundTitle.isEmpty else { return 0 }

        var title = GeniusMatcher.similarity(wantedTitle, foundTitle)
        if title < 1,
           min(wantedTitle.count, foundTitle.count) >= 5,
           wantedTitle.contains(foundTitle) || foundTitle.contains(wantedTitle) {
            let ratio = Double(min(wantedTitle.count, foundTitle.count))
                / Double(max(wantedTitle.count, foundTitle.count))
            title = max(title, ratio >= 0.7 ? 0.8 : title)
        }
        guard title >= 0.8 else { return 0 }

        var artist = 1.0
        let wantedArtists = GeniusMatcher.artistNames(item.artist)
            .map(GeniusMatcher.key)
            .filter { !$0.isEmpty }
        if !wantedArtists.isEmpty {
            let foundArtists = GeniusMatcher.artistNames(track.artist)
                .map(GeniusMatcher.key)
                .filter { !$0.isEmpty }
            let haystack = GeniusMatcher.key(track.artist)
            artist = wantedArtists.map { wanted -> Double in
                if foundArtists.contains(wanted) { return 1 }
                if wanted.count >= 4, haystack.contains(wanted) { return 0.95 }
                return foundArtists.map { GeniusMatcher.similarity(wanted, $0) }.max() ?? 0
            }.max() ?? 0
            // A different artist with the same title is a different song.
            guard artist >= 0.75 else { return 0 }
        } else {
            // Only a title to go on: the title alone must be nearly exact.
            guard title >= 0.95 else { return 0 }
            artist = 0.85
        }

        var value = title * 0.6 + artist * 0.4
        // A remix, live or sped-up cut is another recording.
        let wantedVariants = GeniusMatcher.variants(in: item.title)
        let foundVariants = GeniusMatcher.variants(in: track.title)
        if !foundVariants.subtracting(wantedVariants).isEmpty { value -= 0.25 }
        if !wantedVariants.subtracting(foundVariants).isEmpty { value -= 0.1 }
        return max(0, min(1, value))
    }
}
