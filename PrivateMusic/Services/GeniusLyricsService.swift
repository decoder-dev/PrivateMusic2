import Foundation

struct GeniusLyricsService: Sendable {
    private let searchEndpoint = URL(
        string: "https://genius.com/api/search/multi"
    )!

    func lyrics(for track: Track) async throws -> Lyrics {
        let songURL = try await findSong(for: track)
        let html = try await request(songURL, accept: "text/html")
        guard let text = Self.extractLyrics(from: html),
              !text.isEmpty else {
            throw APIError.server(
                code: 404,
                message: "Genius не вернул текст этой песни."
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
                value: "\(track.artist) \(track.title)"
            )
        ]
        return components.url!
    }

    private func findSong(for track: Track) async throws -> URL {
        var components = URLComponents(
            url: searchEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "5"),
            URLQueryItem(
                name: "q",
                value: "\(track.artist) \(track.title)"
            )
        ]
        guard let url = components?.url else {
            throw APIError.invalidRequest
        }
        let data = try await requestData(url, accept: "application/json")
        let response = try JSONDecoder().decode(
            GeniusSearchResponse.self,
            from: data
        )
        let candidates = response.response.sections
            .flatMap(\.hits)
            .map(\.result)
            .filter {
                $0.title != nil
                    && $0.url != nil
                    && $0.primaryArtist != nil
            }
        let normalizedArtist = Self.normalized(track.artist)
        let normalizedTitle = Self.normalized(track.title)
        let match = candidates.first {
            let artist = Self.normalized($0.primaryArtist?.name ?? "")
            let title = Self.normalized($0.title ?? "")
            return artist.contains(normalizedArtist)
                || normalizedArtist.contains(artist)
                || title == normalizedTitle
        } ?? candidates.first
        guard let rawURL = match?.url,
              let url = URL.secureRemoteURL(rawURL),
              url.host?.lowercased().hasSuffix("genius.com") == true else {
            throw APIError.server(
                code: 404,
                message: "Текст не найден на Genius."
            )
        }
        return url
    }

    private func request(_ url: URL, accept: String) async throws -> String {
        let data = try await requestData(url, accept: accept)
        guard let value = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }
        return value
    }

    private func requestData(
        _ url: URL,
        accept: String
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
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
            throw APIError.invalidResponse
        }
        return data
    }

    private static func extractLyrics(from html: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<div[^>]+data-lyrics-container="true"[^>]*>(.*?)</div>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        let fragments = expression.matches(in: html, range: range).compactMap {
            guard $0.numberOfRanges > 1,
                  let valueRange = Range($0.range(at: 1), in: html) else {
                return nil
            }
            return String(html[valueRange])
        }
        guard !fragments.isEmpty else { return nil }
        let joined = fragments.joined(separator: "<br>")
        guard let attributed = try? NSAttributedString(
            data: Data(joined.utf8),
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
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { lines, line in
                if !line.isEmpty || lines.last?.isEmpty == false {
                    lines.append(line)
                }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }
}

private struct GeniusSearchResponse: Decodable {
    let response: GeniusSearchPayload
}

private struct GeniusSearchPayload: Decodable {
    let sections: [GeniusSearchSection]
}

private struct GeniusSearchSection: Decodable {
    let hits: [GeniusSearchHit]
}

private struct GeniusSearchHit: Decodable {
    let result: GeniusSongResult
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
    let name: String
}
