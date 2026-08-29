import Foundation

@MainActor
@Observable
final class SessionStore {
    private(set) var session: Session?
    private(set) var profile: UserProfile?
    var errorMessage: String?
    private(set) var sessionRevision = 0

    private let keychain: KeychainStore
    private let sessionAccount = "vk-session-v2"
    private let profileAccount = "vk-profile-v1"

    init(keychain: KeychainStore) {
        self.keychain = keychain
        do {
            let saved = try keychain.load(Session.self, account: sessionAccount)
            let isUsable = saved?.isExpired == false
                || saved?.canRefresh == true
            var restored = isUsable ? saved : nil
            if let cachedProfile = try? keychain.load(
                    UserProfile.self,
                    account: profileAccount
               ), let candidate = restored,
               cachedProfile.id == candidate.userID
                    || candidate.userID == nil {
                profile = cachedProfile
                if candidate.userID == nil {
                    let upgraded = candidate.updatingUserID(cachedProfile.id)
                    try? keychain.save(upgraded, account: sessionAccount)
                    restored = upgraded
                }
            }
            session = restored
            AppLog.shared.info(
                .session,
                "Session restored userID=\(restored?.userID.map(String.init) ?? "nil") expired=\(restored?.isExpired ?? false) canRefresh=\(restored?.canRefresh ?? false)"
            )
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.error(
                .session,
                "Session restore failed: \(AppLogRedaction.redact(error.localizedDescription))"
            )
        }
    }

    var accessToken: String? {
        session?.accessToken
    }

    var userAgent: String? {
        session?.userAgent
    }

    /// Single source of truth for the offline account: the session user ID
    /// wins, the restored profile is the fallback. Every offline store must
    /// be configured with this value so account keys never diverge.
    var resolvedOfflineAccountID: Int? {
        session?.userID ?? profile?.id
    }

    func connect(
        accessToken: String,
        userAgent: String?,
        expiresAt: Date? = nil,
        refreshCookie: String? = nil,
        webUserAgent: String? = nil,
        profile: UserProfile
    ) throws {
        let cleaned = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 16 else {
            throw APIError.unauthorized
        }
        let cleanedUserAgent = userAgent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Session(
            accessToken: cleaned,
            userAgent: cleanedUserAgent?.isEmpty == false
                ? cleanedUserAgent
                : nil,
            userID: profile.id,
            expiresAt: expiresAt,
            refreshCookie: refreshCookie,
            webUserAgent: webUserAgent
        )
        try keychain.save(value, account: sessionAccount)
        try? keychain.save(profile, account: profileAccount)
        session = value
        self.profile = profile
        sessionRevision &+= 1
        errorMessage = nil
        AppLog.shared.info(
            .session,
            "Session connected userID=\(profile.id) expiresAt=\(expiresAt?.description ?? "nil") canRefresh=\(value.canRefresh)"
        )
    }

    func updateWebSession(
        _ result: VKWebAuthResult,
        profile: UserProfile
    ) throws {
        try connect(
            accessToken: result.accessToken,
            userAgent: result.apiUserAgent,
            expiresAt: result.expiresAt,
            refreshCookie: result.refreshCookie,
            webUserAgent: result.webUserAgent,
            profile: profile
        )
    }

    @discardableResult
    func setProfile(
        _ profile: UserProfile,
        matchingAccessToken expectedAccessToken: String
    ) -> Bool {
        guard let currentSession = session,
              currentSession.accessToken == expectedAccessToken else {
            return false
        }
        var persistenceError: Error?
        do {
            try keychain.save(profile, account: profileAccount)
        } catch {
            persistenceError = error
        }
        if currentSession.userID != profile.id {
            let updated = currentSession.updatingUserID(profile.id)
            do {
                try keychain.save(updated, account: sessionAccount)
                session = updated
                sessionRevision &+= 1
            } catch {
                persistenceError = persistenceError ?? error
            }
        }
        self.profile = profile
        errorMessage = persistenceError?.localizedDescription
        return true
    }

    func logout() {
        var deletionError: String?
        do {
            try keychain.delete(account: sessionAccount)
        } catch {
            deletionError = error.localizedDescription
        }
        do {
            try keychain.delete(account: profileAccount)
        } catch {
            deletionError = deletionError ?? error.localizedDescription
        }
        session = nil
        profile = nil
        sessionRevision &+= 1
        errorMessage = deletionError
        AppLog.shared.info(.session, "Session logged out")
    }
}
