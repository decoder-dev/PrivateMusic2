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

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private var userAgent: String?

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
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidRequest
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

        for attempt in 0..<retryPolicy.maximumAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
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
                    throw APIError.unauthorized
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw APIError.httpStatus(http.statusCode)
                }

                if let error = vkError {
                    if retryPolicy == .transient,
                       [6, 10].contains(error.errorCode),
                       attempt + 1 < retryPolicy.maximumAttempts {
                        try await retryDelay(
                            attempt: attempt,
                            retryAfter: nil
                        )
                        continue
                    }
                    throw APIError.server(
                        code: error.errorCode,
                        message: error.errorMsg
                    )
                }

                do {
                    return try decoder.decode(Response.self, from: data)
                } catch {
                    throw APIError.decoding(error.localizedDescription)
                }
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                if retryPolicy.shouldRetry(error.code),
                   attempt + 1 < retryPolicy.maximumAttempts {
                    try await retryDelay(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw Self.apiError(for: error)
            } catch {
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
