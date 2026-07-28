import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let settings: AppSettings
    let sessionStore: SessionStore
    let historyStore: ListeningHistoryStore
    let player: AudioPlayer
    let musicService: any MusicService
    let webAuthService: VKWebAuthService

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.configuration = configuration
        self.settings = AppSettings()
        self.sessionStore = SessionStore(keychain: keychain)
        self.historyStore = ListeningHistoryStore()
        self.player = AudioPlayer(
            settings: settings,
            historyStore: historyStore,
            userAgent: sessionStore.userAgent
        )
        self.webAuthService = VKWebAuthService()

        let client = APIClient(
            baseURL: configuration.vkAPIBaseURL,
            userAgent: sessionStore.userAgent
        )
        let service = VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion,
            initialUserID: sessionStore.session?.userID
        )
        self.musicService = service
        player.configureContinuation { [service, sessionStore] in
            guard let token = sessionStore.accessToken else { return [] }
            return try await service.recommendations(accessToken: token)
        }
        player.configureStreamRefresh { [service, sessionStore] track in
            guard let token = sessionStore.accessToken else {
                throw APIError.unauthorized
            }
            return try await service.refreshedTrack(
                track,
                accessToken: token
            )
        }
    }
}
