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
            return L10n.text("Не удалось создать запрос.")
        case .invalidResponse:
            return L10n.text("Сервер вернул некорректный ответ.")
        case .unauthorized:
            return L10n.text("Сессия VK требует обновления.")
        case .offline:
            return L10n.text("Нет подключения к интернету.")
        case .timedOut:
            return L10n.text(
                "Сервер не ответил вовремя. Попробуйте ещё раз."
            )
        case let .server(_, message):
            return message
        case let .transport(message):
            return L10n.format("Сетевая ошибка: %@", message)
        case let .decoding(message):
            return L10n.format(
                "Не удалось обработать ответ: %@",
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
            message: L10n.format("Сервер вернул HTTP %d.", statusCode)
        )
    }
}
