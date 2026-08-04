import Foundation

struct ArtistMetadataService: Sendable {
    private let session: URLSession
    private let deezerSearch = URL(
        string: "https://api.deezer.com/search/artist"
    )!
    private let cache = Cache()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func metadata(for artistName: String) async -> ArtistExternalMetadata? {
        let trimmed = artistName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }

        let cacheKey = Self.normalized(trimmed)
        if let cached = await cache.value(for: cacheKey) {
            return cached
        }

        async let deezer = fetchDeezer(for: trimmed)
        async let biography = fetchBiography(for: trimmed)
        let deezerMeta = await deezer
        let wiki = await biography

        var result = deezerMeta ?? ArtistExternalMetadata(name: trimmed)
        if let wiki {
            if result.biography == nil || result.biography?.isEmpty == true {
                result.biography = wiki.extract
            }
            result.wikipediaURL = wiki.pageURL
            if result.artworkURL == nil {
                result.artworkURL = wiki.thumbnailURL
            }
        }

        guard result.hasEnrichment else { return nil }
        await cache.store(result, for: cacheKey)
        return result
    }

    private func fetchDeezer(
        for artistName: String
    ) async -> ArtistExternalMetadata? {
        var components = URLComponents(
            url: deezerSearch,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: artistName),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components?.url else { return nil }

        do {
            let data = try await requestData(url, accept: "application/json")
            let response = try JSONDecoder().decode(
                DeezerArtistSearchResponse.self,
                from: data
            )
            guard let best = Self.bestMatch(
                in: response.data,
                artist: artistName
            ) else {
                return nil
            }
            return ArtistExternalMetadata(
                name: best.name,
                artworkURL: best.preferredArtworkURL,
                fanCount: best.nbFan,
                albumCount: best.nbAlbum,
                biography: nil,
                deezerURL: best.link.flatMap(URL.secureRemoteURL),
                wikipediaURL: nil
            )
        } catch {
            return nil
        }
    }

    private func fetchBiography(
        for artistName: String
    ) async -> WikipediaSummary? {
        let languages = Self.preferredWikipediaLanguages()
        for language in languages {
            if let summary = await wikipediaSummary(
                title: artistName,
                language: language
            ),
               Self.isUsableBiography(summary, artist: artistName) {
                return summary
            }
        }
        return nil
    }

    private func wikipediaSummary(
        title: String,
        language: String
    ) async -> WikipediaSummary? {
        let encoded = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? title
        guard let url = URL(
            string:
                "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)"
        ) else {
            return nil
        }

        do {
            let data = try await requestData(
                url,
                accept: "application/json"
            )
            return try JSONDecoder().decode(
                WikipediaSummaryPayload.self,
                from: data
            )
            .asSummary()
        } catch {
            return nil
        }
    }

    private func requestData(
        _ url: URL,
        accept: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(
            "PrivateMusic/2.4 (decoder-dev)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return data
    }

    static func bestMatch(
        in candidates: [DeezerArtistCandidate],
        artist: String
    ) -> DeezerArtistCandidate? {
        let ranked = candidates.compactMap {
            candidate -> (DeezerArtistCandidate, Int)? in
            let score = matchScore(
                query: artist,
                candidate: candidate.name
            )
            guard score > 0 else { return nil }
            return (candidate, score)
        }
        return ranked.max(by: { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            return (lhs.0.nbFan ?? 0) < (rhs.0.nbFan ?? 0)
        })?.0
    }

    static func matchScore(query: String, candidate: String) -> Int {
        let target = normalized(query)
        let value = normalized(candidate)
        guard !target.isEmpty, !value.isEmpty else { return 0 }
        if value == target {
            return 100
        }
        if ArtistTrackFilter.matches(candidate, artist: query) {
            return 80
        }
        if value.hasPrefix(target) || target.hasPrefix(value) {
            let shorter = min(value.count, target.count)
            let longer = max(value.count, target.count)
            guard shorter >= 3, Double(shorter) / Double(longer) >= 0.72 else {
                return 0
            }
            return 55
        }
        return 0
    }

    static func isUsableBiography(
        _ summary: WikipediaSummary,
        artist: String
    ) -> Bool {
        guard summary.type == "standard",
              let extract = summary.extract?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty else {
            return false
        }
        return matchScore(query: artist, candidate: summary.title) >= 55
    }

    static func preferredWikipediaLanguages(
        locale: Locale = .current
    ) -> [String] {
        let primary = locale.language.languageCode?.identifier
            ?? locale.languageCode
            ?? "en"
        if primary.lowercased().hasPrefix("ru") {
            return ["ru", "en"]
        }
        if primary.lowercased().hasPrefix("en") {
            return ["en", "ru"]
        }
        return [primary.lowercased(), "en", "ru"]
    }

    static func compactCount(_ value: Int) -> String {
        if #available(iOS 15.0, *) {
            return value.formatted(
                .number
                    .notation(.compactName)
                    .precision(.fractionLength(0...1))
                    .locale(Locale.current)
            )
        }
        return NumberFormatter.localizedString(
            from: NSNumber(value: value),
            number: .decimal
        )
    }

    static func statsLine(
        fanCount: Int?,
        albumCount: Int?
    ) -> String? {
        var parts: [String] = []
        if let fanCount, fanCount > 0 {
            parts.append(
                L10n.format(
                    "%@ слушателей",
                    compactCount(fanCount)
                )
            )
        }
        if let albumCount, albumCount > 0 {
            parts.append(
                L10n.format(
                    "%@ альбомов",
                    compactCount(albumCount)
                )
            )
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    static func clippedBiography(
        _ text: String,
        limit: Int = 280
    ) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        var clipped = String(trimmed[..<end])
        if let lastSpace = clipped.lastIndex(of: " "),
           lastSpace > clipped.startIndex {
            clipped = String(clipped[..<lastSpace])
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ArtistMetadataService {
    struct DeezerArtistCandidate: Decodable, Equatable, Sendable {
        var id: Int
        var name: String
        var link: String?
        var pictureMedium: String?
        var pictureBig: String?
        var pictureXL: String?
        var nbAlbum: Int?
        var nbFan: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case link
            case pictureMedium = "picture_medium"
            case pictureBig = "picture_big"
            case pictureXL = "picture_xl"
            case nbAlbum = "nb_album"
            case nbFan = "nb_fan"
        }

        var preferredArtworkURL: URL? {
            [pictureXL, pictureBig, pictureMedium]
                .compactMap { $0 }
                .compactMap(URL.secureRemoteURL)
                .first
        }
    }

    struct DeezerArtistSearchResponse: Decodable, Sendable {
        var data: [DeezerArtistCandidate]
    }

    struct WikipediaSummary: Equatable, Sendable {
        var type: String
        var title: String
        var extract: String?
        var thumbnailURL: URL?
        var pageURL: URL?
    }

    private struct WikipediaSummaryPayload: Decodable {
        var type: String
        var title: String
        var extract: String?
        var thumbnail: Thumbnail?
        var contentURLs: ContentURLs?

        enum CodingKeys: String, CodingKey {
            case type
            case title
            case extract
            case thumbnail
            case contentURLs = "content_urls"
        }

        struct Thumbnail: Decodable {
            var source: String?
        }

        struct ContentURLs: Decodable {
            var desktop: Desktop?

            struct Desktop: Decodable {
                var page: String?
            }
        }

        func asSummary() -> WikipediaSummary {
            WikipediaSummary(
                type: type,
                title: title,
                extract: extract,
                thumbnailURL: thumbnail?.source.flatMap(URL.secureRemoteURL),
                pageURL: contentURLs?.desktop?.page.flatMap(URL.secureRemoteURL)
            )
        }
    }

    private actor Cache {
        private var values: [String: ArtistExternalMetadata] = [:]

        func value(for key: String) -> ArtistExternalMetadata? {
            values[key]
        }

        func store(_ value: ArtistExternalMetadata, for key: String) {
            if values.count >= 64 {
                values.removeAll(keepingCapacity: true)
            }
            values[key] = value
        }
    }
}
