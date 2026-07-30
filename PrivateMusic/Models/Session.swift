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
        refreshCookie?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
            && webUserAgent?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
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

    func updatingUserID(_ value: Int) -> Session {
        Session(
            accessToken: accessToken,
            userAgent: userAgent,
            userID: value,
            expiresAt: expiresAt,
            refreshCookie: refreshCookie,
            webUserAgent: webUserAgent
        )
    }

    func maintenanceDelay(
        at date: Date = Date(),
        validationInterval: TimeInterval = 900
    ) -> TimeInterval {
        guard let expiresAt else { return validationInterval }
        if needsRefresh(at: date) {
            return validationInterval
        }
        return max(
            min(
                expiresAt.timeIntervalSince(date) - 90,
                validationInterval
            ),
            1
        )
    }
}
