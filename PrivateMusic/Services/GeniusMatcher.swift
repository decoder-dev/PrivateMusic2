import Foundation

/// Decides whether a Genius search hit is the song that is actually playing.
///
/// Genius search is fuzzy by design, so the old rule «best score above zero,
/// otherwise the first hit» happily returned another song by the same artist
/// or a translation page. Here a hit is accepted only when its *title* and its
/// *artist* both match; anything else is "not found", which is better than
/// lyrics of the wrong song.
enum GeniusMatcher {
    struct Candidate: Equatable, Sendable {
        let title: String
        let artist: String
        let url: String
    }

    static let acceptanceThreshold = 100

    // MARK: Query

    /// `Artist Title` without the noise VK titles carry («feat.», brackets,
    /// «- Remastered 2011»), using only the lead artist.
    static func searchQuery(artist: String, title: String) -> String {
        let lead = artistNames(artist).first ?? artist
        let base = displayTitle(title)
        return [lead, base]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Looser second query: the title alone, for when the artist is spelled
    /// differently on Genius (transliteration, stage name).
    static func titleOnlyQuery(title: String) -> String {
        displayTitle(title)
    }

    // MARK: Scoring

    /// Best candidate that clears the bar, or nil.
    static func best(
        in candidates: [Candidate],
        artist: String,
        title: String
    ) -> Candidate? {
        candidates
            .map { (candidate: $0, score: score(
                trackArtist: artist,
                trackTitle: title,
                candidateArtist: $0.artist,
                candidateTitle: $0.title
            )) }
            .filter { $0.score >= acceptanceThreshold }
            .max { $0.score < $1.score }?
            .candidate
    }

    /// 0 means "reject". Title is mandatory; an artist that does not match
    /// rejects the hit too (same title, different song is common: «Intro»).
    static func score(
        trackArtist: String,
        trackTitle: String,
        candidateArtist: String,
        candidateTitle: String
    ) -> Int {
        let wantedTitle = key(displayTitle(trackTitle))
        let foundTitle = key(displayTitle(candidateTitle))
        guard !wantedTitle.isEmpty, !foundTitle.isEmpty else { return 0 }

        // Translations, romanisations and tracklists are other pages that
        // merely quote the song.
        let junk = junkMarkers
        let wantedRaw = (trackTitle + " " + trackArtist).lowercased()
        let foundRaw = (candidateTitle + " " + candidateArtist).lowercased()
        for marker in junk
        where foundRaw.contains(marker) && !wantedRaw.contains(marker) {
            return 0
        }

        let titleScore = titleSimilarity(wantedTitle, foundTitle)
        guard titleScore > 0 else { return 0 }

        var total = titleScore
        let wantedArtists = artistNames(trackArtist).map(key).filter { !$0.isEmpty }
        let foundArtists = artistNames(candidateArtist).map(key).filter { !$0.isEmpty }
        if wantedArtists.isEmpty || isPlaceholderArtist(trackArtist) {
            // Nothing to compare — only an exact title is trustworthy.
            guard titleScore >= 100 else { return 0 }
        } else if foundArtists.isEmpty {
            return 0
        } else if wantedArtists.contains(where: { want in
            foundArtists.contains { artistsMatch(want, $0) }
        }) {
            total += 40
        } else {
            return 0
        }

        // A remix / live / sped-up version is a different recording.
        let wantedVariants = variants(in: trackTitle)
        let foundVariants = variants(in: candidateTitle)
        // Heavy enough that a lone remix never passes for the original.
        if !foundVariants.subtracting(wantedVariants).isEmpty { total -= 60 }
        if !wantedVariants.subtracting(foundVariants).isEmpty { total -= 15 }
        return max(total, 0)
    }

    /// Compatibility wrapper (title + artist score, 0 = reject).
    static func matchScore(
        trackArtist: String,
        trackTitle: String,
        candidateArtist: String,
        candidateTitle: String
    ) -> Int {
        score(
            trackArtist: trackArtist,
            trackTitle: trackTitle,
            candidateArtist: candidateArtist,
            candidateTitle: candidateTitle
        )
    }

    // MARK: Normalisation

    private static let junkMarkers = [
        "translation", "translations", "romanization", "romanizations",
        "перевод", "tracklist", "annotated", "genius "
    ]

    private static let variantMarkers = [
        "remix", "live", "acoustic", "instrumental", "karaoke", "sped up",
        "slowed", "nightcore", "demo", "cover", "ремикс", "кавер",
        "минус", "speed up"
    ]

    private static let suffixMarkers = [
        "remaster", "remix", "live", "version", "edit", "mix", "feat",
        "radio", "acoustic", "deluxe", "bonus", "single", "original",
        "from ", "ремастер", "версия"
    ]

    /// Whole-word match, so «live» does not fire inside «Alive».
    static func variants(in title: String) -> Set<String> {
        let lowered = title.lowercased()
        return Set(variantMarkers.filter { marker in
            lowered.range(
                of: "(?<![\\p{L}])" + marker + "(?![\\p{L}])",
                options: .regularExpression
            ) != nil
        })
    }

    /// Title without brackets, «feat.» tails and «- Remastered» suffixes,
    /// original letters kept.
    static func displayTitle(_ title: String) -> String {
        var value = title
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#] {
            value = value.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        for separator in [" - ", " – ", " — "] {
            if let range = value.range(of: separator) {
                let tail = value[range.upperBound...].lowercased()
                if suffixMarkers.contains(where: { tail.contains($0) }) {
                    value = String(value[..<range.lowerBound])
                }
            }
        }
        if let feat = value.range(
            of: #"(?i)\s(?:feat\.?|ft\.?|при уч\.?|featuring)\s"#,
            options: .regularExpression
        ) {
            value = String(value[..<feat.lowerBound])
        }
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// «A, B feat. C & D» → [A, B, C, D].
    static func artistNames(_ raw: String) -> [String] {
        var value = raw
        for pattern in [
            #"(?i)\s(?:feat\.?|ft\.?|featuring|при уч\.?|vs\.?|with)\s"#,
            #"\s(?:x|×|и|and)\s"#,
            #"[,;/&+]"#
        ] {
            value = value.replacingOccurrences(
                of: pattern,
                with: "|",
                options: .regularExpression
            )
        }
        return value
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isPlaceholderArtist(_ raw: String) -> Bool {
        let value = key(raw)
        return ["unknown", "variousartists", "va", "неизвестен",
                "неизвестныйисполнитель", "variousartist"].contains(value)
    }

    /// Lowercase letters and digits only, Cyrillic transliterated, so
    /// «Скриптонит» and «Skryptonite» land close together.
    static func key(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        var result = ""
        for character in folded {
            if let latin = cyrillic[character] {
                result += latin
            } else if character.isLetter || character.isNumber {
                result.append(character)
            }
        }
        return result
    }

    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
        "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k",
        "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
        "э": "e", "ю": "yu", "я": "ya", "і": "i", "ї": "i", "є": "e",
        "ґ": "g"
    ]

    // MARK: Similarity

    private static func titleSimilarity(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 100 }
        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)
        // One title inside the other only counts when it is most of it:
        // «love» must not match «loveyourself».
        if shorter >= 5,
           lhs.contains(rhs) || rhs.contains(lhs),
           Double(shorter) / Double(longer) >= 0.7 {
            return 75
        }
        if shorter >= 6, similarity(lhs, rhs) >= 0.86 { return 80 }
        return 0
    }

    private static func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if min(lhs.count, rhs.count) >= 4,
           lhs.contains(rhs) || rhs.contains(lhs) {
            return true
        }
        return min(lhs.count, rhs.count) >= 4 && similarity(lhs, rhs) >= 0.8
    }

    /// 1 − edit distance / length of the longer string.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
