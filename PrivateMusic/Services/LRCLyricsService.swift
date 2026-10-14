import Foundation

struct LRCLyricsService: Sendable {
    private let fetch: (@Sendable (URL) async throws -> Data)?

    init(fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.fetch = fetch
    }

    func lyrics(for track: Track) async throws -> Lyrics {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for url in Self.lookupURLs(for: track) {
            try Task.checkCancellation()
            do {
                let data: Data
                if let fetch {
                    data = try await fetch(url)
                } else {
                    var request = URLRequest(url: url)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("PrivateMusic (https://github.com/decoder-dev/PrivateMusic2)",
                                     forHTTPHeaderField: "User-Agent")
                    let (body, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                    if http.statusCode == 404 { continue }
                    guard (200..<300).contains(http.statusCode) else { throw APIError.invalidResponse }
                    data = body
                }
                let candidates = try Self.decodeCandidates(data)
                if let lyrics = Self.bestLyrics(in: candidates, for: track) { return lyrics }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                AppLog.shared.info(.network, "lrclib lookup failed: \(AppLogRedaction.redact(error.localizedDescription))")
                // A transport failure affects the host, not just this query.
                // Move on to the next provider instead of repeating it three times.
                throw error
            }
        }
        throw APIError.server(code: 404, message: L10n.text("no_lyrics_were_found_for_this_track_2"))
    }

    static func lookupURLs(for track: Track) -> [URL] {
        let title = GeniusMatcher.displayTitle(track.title)
        let artist = GeniusMatcher.artistNames(track.artist).first ?? track.artist
        guard !title.isEmpty else { return [] }
        func url(_ path: String, _ items: [URLQueryItem]) -> URL {
            var components = URLComponents(string: path == "get" ? "https://lrclib.net/api/get" : "https://lrclib.net/api/search")!
            components.queryItems = items
            return components.url!
        }
        var urls: [URL] = []
        if let album = track.albumTitle, !album.isEmpty,
           let duration = durationQueryValue(track.duration) {
            urls.append(url("get", [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: duration)
            ]))
        }
        urls.append(url("search", [URLQueryItem(name: "track_name", value: title),
                                   URLQueryItem(name: "artist_name", value: artist)]))
        // Search-only title also finds transliterated names and collaborations;
        // metadata is still checked locally before accepting any result.
        urls.append(url("search", [URLQueryItem(name: "track_name", value: title)]))
        return urls
    }

    static func decodeCandidates(_ data: Data) throws -> [LRCLyricsCandidate] {
        let decoder = JSONDecoder()
        if let candidates = try? decoder.decode([LRCLyricsRecord].self, from: data) { return candidates.compactMap(\.value) }
        return [try decoder.decode(LRCLyricsCandidate.self, from: data)]
    }

    static func bestLyrics(in candidates: [LRCLyricsCandidate], for track: Track) -> Lyrics? {
        let ranked = candidates.compactMap { candidate -> (LRCLyricsCandidate, Int, Double)? in
            let score = GeniusMatcher.score(trackArtist: track.artist, trackTitle: track.title,
                                            candidateArtist: candidate.artistName, candidateTitle: candidate.trackName)
            guard score >= GeniusMatcher.acceptanceThreshold,
                  !(candidate.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(candidate.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let difference = track.duration.isFinite && track.duration > 0
                ? abs(candidate.duration - track.duration) : 0
            return (candidate, score, difference)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return left.2 < right.2
        }
        guard let match = ranked.first?.0 else { return nil }
        let parsed = match.syncedLyrics.map(parseSynced) ?? []
        let text = [match.plainLyrics, parsed.map(\.text).joined(separator: "\n")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let text else { return nil }
        // An edited VK recording can share the words but not the timeline.
        // Never scroll its lyrics using timestamps from a different duration.
        let canSync = track.duration.isFinite && track.duration > 0
            && match.duration.isFinite && abs(match.duration - track.duration) <= 3
        return Lyrics(text: text, source: "LRCLIB", lines: canSync ? parsed : [])
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

struct LRCLyricsCandidate: Decodable, Sendable {
    let trackName: String
    let artistName: String
    let duration: TimeInterval
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct LRCLyricsRecord: Decodable {
    let value: LRCLyricsCandidate?
    init(from decoder: Decoder) throws { value = try? LRCLyricsCandidate(from: decoder) }
}
