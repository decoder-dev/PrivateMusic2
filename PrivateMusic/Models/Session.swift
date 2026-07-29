import Foundation

struct Session: Codable, Equatable, Sendable {
    let accessToken: String
    let userAgent: String?
    let userID: Int?
    let expiresAt: Date?
    let refreshCookie: String?
    let webUserAgent: String?

    var isExpired: Bool {
        isExpired(at: Date())
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    var canRefresh: Bool {
        refreshCookie?.isEmpty == false
            && webUserAgent?.isEmpty == false
    }

    var needsRefresh: Bool {
        needsRefresh(at: Date())
    }

    var shouldRefreshProactively: Bool {
        expiresAt != nil && needsRefresh
    }

    func needsRefresh(
        at date: Date,
        leeway: TimeInterval = 120
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date.addingTimeInterval(leeway)
    }
}
