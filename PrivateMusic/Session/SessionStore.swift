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
            session = saved?.isExpired == false ? saved : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var accessToken: String? {
        session?.accessToken
    }

    func connect(accessToken: String) throws {
        let cleaned = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 16 else {
            throw APIError.unauthorized
        }
        let value = Session(
            accessToken: cleaned,
            userID: nil,
            expiresAt: nil
        )
        try keychain.save(value, account: sessionAccount)
        session = value
    }

    func enterDemoMode() {
        session = Session(
            accessToken: "demo-session-not-for-network",
            userID: 1,
            expiresAt: nil
        )
        profile = UserProfile(
            id: 1,
            firstName: "Private",
            lastName: "Listener",
            photoURL: nil
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

