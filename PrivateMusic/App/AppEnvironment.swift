import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let sessionStore: SessionStore
    let player: AudioPlayer
    let musicService: any MusicService

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.configuration = configuration
        self.sessionStore = SessionStore(keychain: keychain)
        self.player = AudioPlayer()

        let client = APIClient(baseURL: configuration.vkAPIBaseURL)
        self.musicService = VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion
        )
    }
}
