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
        let syncedLines = match.syncedLyrics.map(Self.parseSynced) ?? []
        let synced = syncedLines.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = [plain, synced]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else {
            throw APIError.server(
                code: 404,
                message: "Текст для этого трека не найден."
            )
        }
        return Lyrics(
            text: text,
            source: "LRCLIB",
            lines: syncedLines
        )
    }

    private static func parseSynced(_ value: String) -> [LyricLine] {
        value.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.first == "[",
                  let closing = line.firstIndex(of: "]") else {
                return nil
            }
            let stamp = line[line.index(after: line.startIndex)..<closing]
            let parts = stamp.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else {
                return nil
            }
            let textStart = line.index(after: closing)
            let text = line[textStart...]
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return LyricLine(
                time: minutes * 60 + seconds,
                text: text
            )
        }
        .sorted { $0.time < $1.time }
    }
}

private struct LRCLyricsCandidate: Decodable {
    let duration: TimeInterval
    let plainLyrics: String?
    let syncedLyrics: String?
}
