import Foundation

struct VKWebAuthResult: Sendable {
    let accessToken: String
    let userID: Int?
    let expiresAt: Date?
    let apiUserAgent: String
    let refreshCookie: String
    let webUserAgent: String
}

enum VKWebAuthError: LocalizedError {
    case noSession
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noSession:
            return L10n.text(
                "Сначала завершите вход по номеру телефона на странице VK."
            )
        case let .rejected(message):
            return message.isEmpty
                ? L10n.text("VK не подтвердил веб-сессию.")
                : message
        case .invalidResponse:
            return L10n.text(
                "VK вернул некорректный ответ авторизации."
            )
        }
    }
}

struct VKWebAuthService: Sendable {
    // VK's public web client identifier used by the vk.ru web session itself.
    private let webClientID = "6287487"
    private let tokenURL = URL(string: "https://login.vk.ru/?act=web_token")!

    // Audio API responses depend on the mobile-compatible API user agent.
    private let apiUserAgent =
        "KateMobileAndroid/56 lite-460 (Android 4.4.2; SDK 19; x86; "
        + "unknown Android SDK built for x86; ru)"

    func exchange(
        cookieHeader: String,
        webUserAgent: String
    ) async throws -> VKWebAuthResult {
        let cleanedCookies = cookieHeader.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let cleanedWebUserAgent = webUserAgent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedCookies.isEmpty,
              !cleanedWebUserAgent.isEmpty else {
            throw VKWebAuthError.noSession
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)

        var request = URLRequest(
            url: tokenURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://vk.ru", forHTTPHeaderField: "Origin")
        request.setValue("https://vk.ru/", forHTTPHeaderField: "Referer")
        request.setValue(
            cleanedCookies,
            forHTTPHeaderField: "Cookie"
        )
        request.setValue(
            cleanedWebUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = "version=1&app_id=\(webClientID)"
            .data(using: .utf8)

        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw VKWebAuthError.invalidResponse
                }
                if (http.statusCode == 429 || http.statusCode >= 500),
                   attempt < 2 {
                    try await Task.sleep(
                        for: .milliseconds(500 * (attempt + 1))
                    )
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw VKWebAuthError.invalidResponse
                }
                let headers = http.allHeaderFields.reduce(
                    into: [String: String]()
                ) { result, item in
                    guard let key = item.key as? String,
                          let value = item.value as? String else {
                        return
                    }
                    result[key] = value
                }
                return try decode(
                    data,
                    cookies: Self.mergingCookieHeader(
                        cleanedCookies,
                        responseHeaders: headers,
                        url: tokenURL
                    ),
                    webUserAgent: cleanedWebUserAgent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                if RequestRetryPolicy.transient.shouldRetry(error.code),
                   attempt < 2 {
                    try await Task.sleep(
                        for: .milliseconds(500 * (attempt + 1))
                    )
                    continue
                }
                switch error.code {
                case .notConnectedToInternet,
                     .networkConnectionLost,
                     .dataNotAllowed,
                     .internationalRoamingOff:
                    throw APIError.offline
                case .timedOut:
                    throw APIError.timedOut
                default:
                    throw APIError.transport(error.localizedDescription)
                }
            }
        }
        throw VKWebAuthError.invalidResponse
    }

    static func mergingCookieHeader(
        _ original: String,
        responseHeaders: [String: String],
        url: URL
    ) -> String {
        var values = original
            .split(separator: ";")
            .reduce(into: [String: String]()) { result, component in
                let pair = component.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard pair.count == 2 else { return }
                let name = pair[0].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !name.isEmpty else { return }
                result[name] = String(pair[1])
            }
        let updated = HTTPCookie.cookies(
            withResponseHeaderFields: responseHeaders,
            for: url
        )
        for cookie in updated {
            values[cookie.name] = cookie.value
        }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func decode(
        _ data: Data,
        cookies: String,
        webUserAgent: String
    ) throws -> VKWebAuthResult {
        let envelope: WebTokenEnvelope
        do {
            envelope = try JSONDecoder().decode(
                WebTokenEnvelope.self,
                from: data
            )
        } catch {
            throw VKWebAuthError.invalidResponse
        }

        guard envelope.type == "okay", let payload = envelope.data else {
            throw VKWebAuthError.rejected(envelope.errorInfo ?? "")
        }
        let cleanedToken = payload.accessToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard cleanedToken.count >= 16 else {
            throw VKWebAuthError.invalidResponse
        }

        let expiresAt = payload.expires.flatMap { raw -> Date? in
            guard raw > 0 else { return nil }
            // Current web_token returns Unix seconds. Keep duration-form
            // compatibility in case VK changes the response shape.
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(raw))
            }
            return Date().addingTimeInterval(TimeInterval(raw))
        }

        return VKWebAuthResult(
            accessToken: cleanedToken,
            userID: payload.userID,
            expiresAt: expiresAt,
            apiUserAgent: apiUserAgent,
            refreshCookie: cookies,
            webUserAgent: webUserAgent
        )
    }
}

private struct WebTokenEnvelope: Decodable {
    let type: String
    let data: WebTokenPayload?
    let errorInfo: String?

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case errorInfo = "error_info"
    }
}

private struct WebTokenPayload: Decodable {
    let accessToken: String
    let userID: Int?
    let expires: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case userID = "user_id"
        case expires
    }
}
