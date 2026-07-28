import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var profile: UserProfile?
    @Published var errorMessage: String?

    private let keychain: KeychainStore
    private let sessionAccount = "vk-session-v2"

    init(keychain: KeychainStore) {
        self.keychain = keychain
        do {
            let saved = try keychain.load(Session.self, account: sessionAccount)
            session = saved?.isExpired == false || saved?.canRefresh == true
                ? saved
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var accessToken: String? {
        session?.accessToken
    }

    var userAgent: String? {
        session?.userAgent
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
        session = value
        self.profile = profile
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

    func setProfile(_ profile: UserProfile) {
        self.profile = profile
    }

    func logout() {
        do {
            try keychain.delete(account: sessionAccount)
        } catch {
            errorMessage = error.localizedDescription
        }
        session = nil
        profile = nil
    }
}
