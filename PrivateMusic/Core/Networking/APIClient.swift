import Foundation

enum RequestRetryPolicy: Sendable, Equatable {
    case transient
    /// Stream URL refresh already runs inside AudioPlayer's condition-aware
    /// same-track recovery loop. Retrying here as well multiplies one outage
    /// into 24–36 requests and can hold each outer attempt for 90 seconds.
    case playbackRecovery
    case never

    var maximumAttempts: Int {
        switch self {
        case .transient: 3
        case .playbackRecovery, .never: 1
        }
    }

    var requestTimeout: TimeInterval {
        switch self {
        case .transient, .never: 30
        case .playbackRecovery: 12
        }
    }

    /// Stream refresh must fail immediately when there is no path. Waiting
    /// for connectivity here stacked under AudioPlayer's same-track loop
    /// and left tracks on “loading…” for the full timeout.
    var waitsForConnectivity: Bool {
        switch self {
        case .playbackRecovery: false
        case .transient, .never: true
        }
    }

    func shouldRetry(_ code: URLError.Code) -> Bool {
        guard self == .transient else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .resourceUnavailable
        ].contains(code)
    }

    func shouldRetry(statusCode: Int) -> Bool {
        guard self == .transient else { return false }
        return statusCode == 408
            || statusCode == 429
            || [500, 502, 503, 504].contains(statusCode)
    }
}

/// Some VK methods are simply not there for a given token. `audio
/// .getAlbumsByArtist` answers `error_code 3, "Unknown method passed"` on
/// the accounts this app signs in with, and the artist screen falls back
/// to `catalog.getAudioArtist`, which works — so nothing is broken, but
/// every artist page opened begins with a request that cannot succeed.
///
/// The answer will not change while the app is running, so it is worth
/// remembering. Only for the session: a new launch may hold a different
/// token, and the memo is not worth persisting to be wrong across one.
enum VKMethodAvailabilityPolicy {
    /// VK's "Unknown method passed". Not a rate limit and not an outage —
    /// asking again with the same token gets the same answer.
    static let unknownMethodCode = 3

    static func isPermanentlyUnavailable(code: Int) -> Bool {
        code == unknownMethodCode
    }
}

/// Whether two requests in flight at the same moment may share one answer.
///
/// From a launch on constrained cellular: `audio.get&offset=0` sent four
/// times inside one minute at ~250 KB a piece, `audio.getRecommendations`
/// seven times at ~270 KB, `users.get` three or four times — every launch,
/// same path, same parameters, same token. Several screens each decided
/// they needed the library and none of them could see the others, so a cold
/// start cost 2.7 MB, most of it the same bytes fetched again.
///
/// Only reads may share an answer. Two `audio.add` calls with identical
/// parameters are two intents and must stay two requests, so the line is
/// drawn on the method name rather than on a list that would fall behind
/// VK's API — anything that is not recognisably a read keeps its own
/// request.
enum RequestCoalescingPolicy {
    static func sharesAnswer(path: String) -> Bool {
        guard let method = path.split(separator: ".").last?.lowercased(),
              !method.isEmpty else {
            return false
        }
        return method.hasPrefix("get") || method.hasPrefix("search")
    }

    /// Identical down to the token: a request signed by a different session
    /// is a different request, and coalescing across a rotation would hand
    /// back an answer fetched with a token that has since been replaced.
    static func key(
        path: String,
        body: Data?,
        retryPolicy: RequestRetryPolicy
    ) -> String? {
        guard sharesAnswer(path: path), let body else { return nil }
        return "\(retryPolicy)\n\(path)\n\(String(decoding: body, as: UTF8.self))"
    }
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private var userAgent: String?
    /// Paths VK has already answered with "Unknown method passed".
    /// See `VKMethodAvailabilityPolicy`.
    private var unavailableMethods = Set<String>()
    /// Reads currently on the wire, by `RequestCoalescingPolicy.key`.
    private var inFlightReads: [String: Task<Data, Error>] = [:]

    init(
        baseURL: URL,
        session: URLSession? = nil,
        userAgent: String? = nil
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.waitsForConnectivity = false
            configuration.allowsCellularAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }

        self.decoder = JSONDecoder()
    }

    func setUserAgent(_ value: String?) {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        userAgent = cleaned?.isEmpty == false ? cleaned : nil
    }

    func post<Response: Decodable>(
        path: String,
        form: [String: String],
        retryPolicy: RequestRetryPolicy = .transient,
        responseType: Response.Type
    ) async throws -> Response {
        let data = try await responseData(
            path: path,
            form: form,
            retryPolicy: retryPolicy
        )
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            AppLog.shared.error(
                .api,
                "POST \(path) decode failed: \(AppLogRedaction.redact(error.localizedDescription))"
            )
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// The raw answer, shared with any identical read already on the wire.
    private func responseData(
        path: String,
        form: [String: String],
        retryPolicy: RequestRetryPolicy
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidRequest
        }
        // Already asked this session and told the method does not exist.
        // Callers all have a fallback — throwing the same error they would
        // have got sends them straight to it.
        if unavailableMethods.contains(path) {
            throw APIError.server(
                code: VKMethodAvailabilityPolicy.unknownMethodCode,
                message: "Unknown method passed"
            )
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: retryPolicy.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.urlQueryEncoded)=\(value.urlQueryEncoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        guard let key = RequestCoalescingPolicy.key(
            path: path,
            body: request.httpBody,
            retryPolicy: retryPolicy
        ) else {
            return try await send(
                request,
                path: path,
                form: form,
                retryPolicy: retryPolicy
            )
        }
        if let existing = inFlightReads[key] {
            AppLog.shared.debug(
                .api,
                "POST \(path) shared with an identical request already in flight"
            )
            return try await existing.value
        }
        let shared = Task { [self] in
            try await send(
                request,
                path: path,
                form: form,
                retryPolicy: retryPolicy
            )
        }
        inFlightReads[key] = shared
        defer { inFlightReads[key] = nil }
        return try await shared.value
    }

    private func send(
        _ request: URLRequest,
        path: String,
        form: [String: String],
        retryPolicy: RequestRetryPolicy
    ) async throws -> Data {
        for attempt in 0..<retryPolicy.maximumAttempts {
            let started = Date()
            AppLog.shared.debug(
                .api,
                "POST \(path) attempt=\(attempt + 1)/\(retryPolicy.maximumAttempts) body=\(AppLogRedaction.describeForm(form))"
            )
            do {
                let (data, response) = try await session.data(for: request)
                let elapsedMs = Date().timeIntervalSince(started) * 1000
                guard let http = response as? HTTPURLResponse else {
                    AppLog.shared.error(.api, "POST \(path) invalid response")
                    throw APIError.invalidResponse
                }
                AppLog.shared.debug(
                    .api,
                    "POST \(path) status=\(http.statusCode) bytes=\(data.count) duration=\(String(format: "%.0fms", elapsedMs))"
                )
                if retryPolicy.shouldRetry(
                    statusCode: http.statusCode
                ),
                   attempt + 1 < retryPolicy.maximumAttempts {
                    try await retryDelay(
                        attempt: attempt,
                        retryAfter: http.value(
                            forHTTPHeaderField: "Retry-After"
                        )
                    )
                    continue
                }
                let vkEnvelope = try? decoder.decode(
                    VKErrorEnvelope.self,
                    from: data
                )
                let vkError = vkEnvelope?.error
                if http.statusCode == 401 || vkError?.errorCode == 5 {
                    AppLog.shared.error(.api, "POST \(path) unauthorized")
                    throw APIError.unauthorized
                }
                guard (200..<300).contains(http.statusCode) else {
                    AppLog.shared.error(
                        .api,
                        "POST \(path) http=\(http.statusCode)"
                    )
                    throw APIError.httpStatus(http.statusCode)
                }

                if let error = vkError {
                    if retryPolicy == .transient,
                       [6, 10].contains(error.errorCode),
                       attempt + 1 < retryPolicy.maximumAttempts {
                        AppLog.shared.info(
                            .api,
                            "POST \(path) vk=\(error.errorCode) retrying: \(AppLogRedaction.redact(error.errorMsg))"
                        )
                        try await retryDelay(
                            attempt: attempt,
                            retryAfter: nil
                        )
                        continue
                    }
                    if VKMethodAvailabilityPolicy.isPermanentlyUnavailable(
                        code: error.errorCode
                    ) {
                        unavailableMethods.insert(path)
                    }
                    AppLog.shared.error(
                        .api,
                        "POST \(path) vk=\(error.errorCode) \(AppLogRedaction.redact(error.errorMsg))"
                    )
                    throw APIError.server(
                        code: error.errorCode,
                        message: error.errorMsg
                    )
                }

                return data
            } catch let error as APIError {
                AppLog.shared.error(
                    .api,
                    "POST \(path) apiError=\(AppLogRedaction.redact(error.localizedDescription))"
                )
                throw error
            } catch is CancellationError {
                AppLog.shared.debug(.api, "POST \(path) cancelled")
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                AppLog.shared.debug(.api, "POST \(path) url cancelled")
                throw CancellationError()
            } catch let error as URLError {
                AppLog.shared.error(
                    .api,
                    "POST \(path) url=\(error.code.rawValue) \(AppLogRedaction.redact(error.localizedDescription))"
                )
                if retryPolicy.shouldRetry(error.code),
                   attempt + 1 < retryPolicy.maximumAttempts {
                    try await retryDelay(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw Self.apiError(for: error)
            } catch {
                AppLog.shared.error(
                    .api,
                    "POST \(path) transport \(AppLogRedaction.redact(error.localizedDescription))"
                )
                throw APIError.transport(error.localizedDescription)
            }
        }
        throw APIError.invalidResponse
    }

    private func retryDelay(
        attempt: Int,
        retryAfter: String?
    ) async throws {
        let serverDelay = retryAfter.flatMap(Double.init)
        let exponential = min(pow(2, Double(attempt)) * 0.55, 4)
        let jitter = Double.random(in: 0.85...1.15)
        let delay = min(max(serverDelay ?? exponential * jitter, 0.2), 8)
        try await Task.sleep(for: .seconds(delay))
    }

    private static func apiError(for error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .transport(error.localizedDescription)
        }
    }
}

private struct VKErrorEnvelope: Decodable {
    let error: VKErrorPayload?
}

private struct VKErrorPayload: Decodable {
    let errorCode: Int
    let errorMsg: String

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMsg = "error_msg"
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(
            withAllowedCharacters: .urlQueryValueAllowed
        ) ?? self
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
