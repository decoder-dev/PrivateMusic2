import Foundation

struct Session: Codable, Equatable, Sendable {
    let accessToken: String
    let userAgent: String?
    let userID: Int?
    let expiresAt: Date?
    let refreshCookie: String?
    let webUserAgent: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var canRefresh: Bool {
        refreshCookie?.isEmpty == false
            && webUserAgent?.isEmpty == false
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(120)
    }
}
