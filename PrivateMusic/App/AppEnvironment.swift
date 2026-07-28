import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let settings: AppSettings
    let sessionStore: SessionStore
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
        self.player = AudioPlayer(
            settings: settings,
            userAgent: sessionStore.userAgent
        )
        self.webAuthService = VKWebAuthService()

        let client = APIClient(
            baseURL: configuration.vkAPIBaseURL,
            userAgent: sessionStore.userAgent
        )
        self.musicService = VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion,
            initialUserID: sessionStore.session?.userID
        )
    }
}
