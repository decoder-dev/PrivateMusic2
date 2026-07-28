import Foundation

struct Session: Codable, Equatable, Sendable {
    let accessToken: String
    let userID: Int?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

