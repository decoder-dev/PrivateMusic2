import Foundation

struct GeniusLyricsService: Sendable {
    private let fetch: (@Sendable (URL) async throws -> Data)?

    init(fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.fetch = fetch
    }

    private let searchEndpoint = URL(
        string: "https://genius.com/api/search/song"
    )!

    func lyrics(for track: Track) async throws -> Lyrics {
        let songURL = try await findSong(for: track)
        let html = try await request(songURL, accept: "text/html", kind: .html)
        let extracted = await MainActor.run { Self.extractLyrics(from: html) }
        try Task.checkCancellation()
        guard let text = extracted,
              !text.isEmpty else {
            throw APIError.server(
                code: 404,
                message: L10n.text("genius_did_not_return_lyrics_for_this_song")
            )
        }
        return Lyrics(
            text: text,
            source: "Genius",
            sourceURL: songURL
        )
    }

    static func searchPageURL(for track: Track) -> URL {
        var components = URLComponents(
            string: "https://genius.com/search"
        )!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: GeniusMatcher.searchQuery(
                    artist: track.artist,
                    title: track.title
                )
            )
        ]
        return components.url!
    }

    private func findSong(for track: Track) async throws -> URL {
        // Lead-artist query first; the title alone only when that finds no
        // confident match (stage names and transliterations differ).
        let queries = [
            GeniusMatcher.searchQuery(artist: track.artist, title: track.title),
            GeniusMatcher.titleOnlyQuery(title: track.title)
        ]
        var seen = Set<String>()
        var searched = false
        var lastError: Error?
        for query in queries where !query.isEmpty && seen.insert(query).inserted {
            // One query failing (a changed reply shape, a hiccup) must not
            // stop the next one from being tried.
            let candidates: [GeniusMatcher.Candidate]
            do {
                candidates = try await search(query)
                searched = true
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GeniusLookupError {
                throw error
            } catch {
                try Task.checkCancellation()
                lastError = error
                AppLog.shared.info(
                    .network,
                    "genius search failed: \(AppLogRedaction.redact(error.localizedDescription))"
                )
                continue
            }
            if let match = GeniusMatcher.best(
                in: candidates,
                artist: track.artist,
                title: track.title
            ),
               let url = GeniusResponsePolicy.songURL(match.url) {
                return url
            }
        }
        if !searched, let lastError { throw lastError }
        throw APIError.server(
            code: 404,
            message: L10n.text("lyrics_were_not_found_on_genius")
        )
    }

    private func search(_ query: String) async throws -> [GeniusMatcher.Candidate] {
        var components = URLComponents(
            url: searchEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "8"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components?.url else {
            throw APIError.invalidRequest
        }
        let data = try await requestData(
            url,
            accept: "application/json",
            kind: .json
        )
        return try Self.searchCandidates(from: data)
    }

    static func searchCandidates(from data: Data) throws -> [GeniusMatcher.Candidate] {
        let response = try JSONDecoder().decode(GeniusSearchResponse.self, from: data)
        return (response.response.hits + response.response.sections.flatMap(\.hits))
            .filter { hit in
                guard let type = hit.type else { return true }
                return ["song", "lyric", "top_hit"].contains(type)
            }
            .compactMap { hit in
                guard let title = hit.result.title, let url = hit.result.url,
                      GeniusResponsePolicy.songURL(url) != nil,
                      let artist = hit.result.primaryArtist?.name else { return nil }
                return GeniusMatcher.Candidate(title: title, artist: artist, url: url)
            }
    }

    private func request(
        _ url: URL,
        accept: String,
        kind: GeniusWebFetcher.Kind
    ) async throws -> String {
        let data = try await requestData(url, accept: accept, kind: kind)
        guard let value = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }
        return value
    }

    private func requestData(
        _ url: URL,
        accept: String,
        kind: GeniusWebFetcher.Kind
    ) async throws -> Data {
        if let fetch { return try await fetch(url) }
        do {
            let data = try await directData(url, accept: accept)
            guard let text = String(data: data, encoding: .utf8),
                  GeniusResponsePolicy.isUsable(text, kind: kind) else {
                // A challenge can be returned with HTTP 200. Validate the
                // body here so it reaches the browser fallback too.
                throw APIError.invalidResponse
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError
            where [.cancelled, .notConnectedToInternet,
                   .networkConnectionLost].contains(error.code) {
            throw error
        } catch {
            // WebKit may succeed when the HTTP client is rejected. If it
            // needs interaction, offer the visible browser in LyricsView.
            return try await GeniusWebFetcher.fetch(url, kind: kind)
        }
    }

    private func directData(
        _ url: URL,
        accept: String
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://genius.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            AppLog.shared.info(
                .network,
                "genius direct request rejected status=\((response as? HTTPURLResponse)?.statusCode ?? -1) host=\(url.host ?? "-")"
            )
            throw APIError.invalidResponse
        }
        return data
    }

    @MainActor static func extractLyrics(from html: String) -> String? {
        let containerPatterns = [
            #"<div\b[^>]*\bdata-lyrics-container\s*=\s*["']true["'][^>]*>"#,
            #"<div\b[^>]*\bclass\s*=\s*["'][^"']*(?:Lyrics__Container|\blyrics\b)[^"']*["'][^>]*>"#
        ]
        let containerExpressions = containerPatterns.compactMap {
            try? NSRegularExpression(
                pattern: $0,
                options: [.caseInsensitive]
            )
        }
        guard containerExpressions.count == containerPatterns.count,
              let divExpression = try? NSRegularExpression(
                pattern: #"</?div\b[^>]*>"#,
                options: [.caseInsensitive]
        ) else {
            return nil
        }

        let source = html as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var openingsByLocation: [Int: NSTextCheckingResult] = [:]
        for expression in containerExpressions {
            for match in expression.matches(in: html, range: fullRange) {
                openingsByLocation[match.range.location] = match
            }
        }
        let openings = openingsByLocation.values.sorted {
            $0.range.location < $1.range.location
        }
        let fragments: [String] = openings.compactMap { opening in
            let contentStart = NSMaxRange(opening.range)
            guard contentStart < source.length else { return nil }
            let searchRange = NSRange(
                location: contentStart,
                length: source.length - contentStart
            )
            var depth = 1
            for tag in divExpression.matches(in: html, range: searchRange) {
                let value = source.substring(with: tag.range)
                if value.hasPrefix("</") || value.hasPrefix("</".uppercased()) {
                    depth -= 1
                    if depth == 0 {
                        return source.substring(
                            with: NSRange(
                                location: contentStart,
                                length: tag.range.location - contentStart
                            )
                        )
                    }
                } else {
                    depth += 1
                }
            }
            return nil
        }
        guard !fragments.isEmpty else { return nil }
        let joined = fragments.joined(separator: "<br>")
        // The importer only needs text, entities and line breaks. Strip
        // resource-bearing markup so lyric extraction cannot fetch images
        // or stylesheets and stall the main-thread HTML importer.
        let safeHTML = joined
            .replacingOccurrences(of: #"(?is)<(script|style|iframe|object)\b[^>]*>.*?</\1\s*>"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?(?:div|p)\b[^>]*>|<br\b[^>]*>"#,
                                  with: "<br>", options: .regularExpression)
            .replacingOccurrences(of: #"<(?!br>)[^>]*>"#, with: "", options: .regularExpression)
        guard let attributed = try? NSAttributedString(
            data: Data(safeHTML.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return nil
        }
        return attributed.string
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                String($0).trimmingCharacters(
                    in: CharacterSet.whitespaces
                )
            }
            .reduce(into: [String]()) { lines, line in
                if !line.isEmpty || lines.last?.isEmpty == false {
                    lines.append(line)
                }
            }
            .joined(separator: "\n")
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
    }

    static func matchScore(
        trackArtist: String,
        trackTitle: String,
        candidateArtist: String,
        candidateTitle: String
    ) -> Int {
        GeniusMatcher.matchScore(
            trackArtist: trackArtist,
            trackTitle: trackTitle,
            candidateArtist: candidateArtist,
            candidateTitle: candidateTitle
        )
    }
}

private struct GeniusSearchResponse: Decodable {
    let response: GeniusSearchPayload
}

/// The reply shape is read leniently: a section without hits, a hit without
/// a result or an artist without a name is skipped instead of failing the
/// whole search.
private struct GeniusSearchPayload: Decodable {
    let sections: [GeniusSearchSection]
    let hits: [GeniusSearchHit]

    enum CodingKeys: String, CodingKey { case sections, hits }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hits = ((try? container.decode([GeniusLossy<GeniusSearchHit>].self, forKey: .hits)) ?? []).compactMap(\.value)
        sections = ((try? container.decode(
            [GeniusLossy<GeniusSearchSection>].self,
            forKey: .sections
        )) ?? []).compactMap(\.value)
    }
}

private struct GeniusSearchSection: Decodable {
    let hits: [GeniusSearchHit]

    enum CodingKeys: String, CodingKey { case hits }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hits = ((try? container.decode(
            [GeniusLossy<GeniusSearchHit>].self,
            forKey: .hits
        )) ?? []).compactMap(\.value)
    }
}

private struct GeniusSearchHit: Decodable {
    let type: String?
    let result: GeniusSongResult
}

private struct GeniusLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct GeniusSongResult: Decodable {
    let title: String?
    let url: String?
    let primaryArtist: GeniusArtist?

    enum CodingKeys: String, CodingKey {
        case title
        case url
        case primaryArtist = "primary_artist"
    }
}

private struct GeniusArtist: Decodable {
    let name: String?
}

enum GeniusLookupError: Error, LocalizedError {
    case accessRestricted

    var errorDescription: String? { L10n.text("lyrics.genius_access_restricted") }
}
