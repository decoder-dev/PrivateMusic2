import Foundation

enum APIError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case offline
    case timedOut
    case server(code: Int, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return L10n.text("could_not_create_the_request")
        case .invalidResponse:
            return L10n.text("the_server_returned_an_invalid_response")
        case .unauthorized:
            return L10n.text("the_vk_session_needs_to_be_refreshed")
        case .offline:
            return L10n.text("no_internet_connection")
        case .timedOut:
            return L10n.text(
                "the_server_timed_out_try_again"
            )
        case let .server(_, message):
            return message
        case let .transport(message):
            return L10n.format("network_error_0", message)
        case let .decoding(message):
            return L10n.format(
                "could_not_process_the_response_0",
                message
            )
        }
    }

    var isConnectivityFailure: Bool {
        switch self {
        case .offline, .timedOut, .transport:
            return true
        default:
            return false
        }
    }

    static func httpStatus(_ statusCode: Int) -> APIError {
        if statusCode == 401 {
            return .unauthorized
        }
        return .server(
            code: statusCode,
            message: L10n.format("the_server_returned_http_d0", statusCode)
        )
    }
}
