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
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if let duration = Self.durationQueryValue(track.duration) {
            components?.queryItems?.append(URLQueryItem(name: "duration", value: duration))
        }
        guard let url = components?.url else {
            throw APIError.invalidRequest
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

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
                message: L10n.text("no_lyrics_were_found_for_this_track_2")
            )
        }

        let candidates = try JSONDecoder().decode(
            [LRCLyricsCandidate].self,
            from: data
        )
        guard let match = candidates.filter({ candidate in
            [candidate.plainLyrics, candidate.syncedLyrics].compactMap { $0 }
                .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }).min(by: {
            abs($0.duration - track.duration)
                < abs($1.duration - track.duration)
        }),
              !track.duration.isFinite || track.duration <= 0
                || abs(match.duration - track.duration)
                    <= max(12, track.duration * 0.08) else {
            throw APIError.server(
                code: 404,
                message: L10n.text("no_lyrics_were_found_for_this_track_2")
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
                message: L10n.text("no_lyrics_were_found_for_this_track_2")
            )
        }
        return Lyrics(
            text: text,
            source: "LRCLIB",
            lines: syncedLines
        )
    }

    static func durationQueryValue(_ duration: TimeInterval) -> String? {
        guard duration.isFinite, duration > 0,
              duration.rounded() < Double(Int.max) else { return nil }
        return String(Int(duration.rounded()))
    }

    static func parseSynced(_ value: String) -> [LyricLine] {
        var identifiers = Set<String>()
        return value.split(separator: "\n").flatMap { rawLine -> [LyricLine] in
            var remainder = rawLine.trimmingCharacters(in: .whitespaces)
            var times: [TimeInterval] = []
            while remainder.first == "[", let closing = remainder.firstIndex(of: "]") {
                let stamp = remainder[remainder.index(after: remainder.startIndex)..<closing]
                let parts = stamp.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      let minutes = Double(parts[0]), minutes.isFinite, minutes >= 0,
                      let seconds = Double(parts[1]), seconds.isFinite, (0..<60).contains(seconds),
                      (minutes * 60 + seconds).isFinite else { return [] }
                times.append(minutes * 60 + seconds)
                remainder = String(remainder[remainder.index(after: closing)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !remainder.isEmpty else { return [] }
            return times.compactMap { time in
                let line = LyricLine(time: time, text: remainder)
                return identifiers.insert(line.id).inserted ? line : nil
            }
        }
        .sorted { $0.time < $1.time }
    }
}

private struct LRCLyricsCandidate: Decodable {
    let duration: TimeInterval
    let plainLyrics: String?
    let syncedLyrics: String?
}
