import Foundation

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = true
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }

        self.decoder = JSONDecoder()
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
        request.httpBody = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.urlQueryEncoded)=\(value.urlQueryEncoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server(
                    code: http.statusCode,
                    message: "Сервер вернул HTTP \(http.statusCode)."
                )
            }

            if let envelope = try? decoder.decode(VKErrorEnvelope.self, from: data),
               let error = envelope.error {
                if error.errorCode == 5 {
                    throw APIError.unauthorized
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
        } catch {
            throw APIError.transport(error.localizedDescription)
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
