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
            return "Не удалось создать запрос."
        case .invalidResponse:
            return "Сервер вернул некорректный ответ."
        case .unauthorized:
            return "Сессия недействительна. Войдите снова."
        case .offline:
            return "Нет подключения к интернету."
        case .timedOut:
            return "Сервер не ответил вовремя. Попробуйте ещё раз."
        case let .server(_, message):
            return message
        case let .transport(message):
            return "Сетевая ошибка: \(message)"
        case let .decoding(message):
            return "Не удалось обработать ответ: \(message)"
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
}
