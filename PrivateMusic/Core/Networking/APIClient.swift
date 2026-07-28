import Foundation

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
            configuration.waitsForConnectivity = true
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
        responseType: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidRequest
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
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

        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
                if (http.statusCode == 429 || http.statusCode >= 500),
                   attempt < 2 {
                    await retryDelay(attempt: attempt)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw APIError.server(
                        code: http.statusCode,
                        message: "Сервер вернул HTTP \(http.statusCode)."
                    )
                }

                if let envelope = try? decoder.decode(
                    VKErrorEnvelope.self,
                    from: data
                ), let error = envelope.error {
                    if error.errorCode == 5 {
                        throw APIError.unauthorized
                    }
                    if [6, 10].contains(error.errorCode), attempt < 2 {
                        await retryDelay(attempt: attempt)
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
            } catch {
                if attempt < 2 {
                    await retryDelay(attempt: attempt)
                    continue
                }
                throw APIError.transport(error.localizedDescription)
            }
        }
        throw APIError.invalidResponse
    }

    private func retryDelay(attempt: Int) async {
        let delay = UInt64(attempt + 1) * 350_000_000
        try? await Task.sleep(nanoseconds: delay)
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
