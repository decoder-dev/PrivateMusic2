import Foundation

struct LRCLyricsService: Sendable {
    private let endpoint = URL(string: "https://lrclib.net/api/search")!

    func lyrics(for track: Track) async throws -> Lyrics {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(
                name: "duration",
                value: String(Int(track.duration.rounded()))
            )
        ]
        guard let url = components?.url else {
            throw APIError.invalidRequest
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "PrivateMusic/2.4 (decoder-dev)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                code: 404,
                message: "Текст для этого трека не найден."
            )
        }

        let candidates = try JSONDecoder().decode(
            [LRCLyricsCandidate].self,
            from: data
        )
        guard let match = candidates.min(by: {
            abs($0.duration - track.duration)
                < abs($1.duration - track.duration)
        }) else {
            throw APIError.server(
                code: 404,
                message: "Текст для этого трека не найден."
            )
        }

        let plain = match.plainLyrics?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let synced = match.syncedLyrics.map(Self.stripTimestamps)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = [plain, synced]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else {
            throw APIError.server(
                code: 404,
                message: "Текст для этого трека не найден."
            )
        }
        return Lyrics(text: text, source: "LRCLIB")
    }

    private static func stripTimestamps(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\[[0-9:.]+\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
    }
}

private struct LRCLyricsCandidate: Decodable {
    let duration: TimeInterval
    let plainLyrics: String?
    let syncedLyrics: String?
}
