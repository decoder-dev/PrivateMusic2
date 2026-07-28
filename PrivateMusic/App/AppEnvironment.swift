import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let sessionStore: SessionStore
    let player: AudioPlayer
    @Published private(set) var musicService: any MusicService
    private let liveService: any MusicService

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.configuration = configuration
        self.sessionStore = SessionStore(keychain: keychain)
        self.player = AudioPlayer()

        let client = APIClient(baseURL: configuration.vkAPIBaseURL)
        let liveService = VKMusicService(client: client)
        self.liveService = liveService
        self.musicService = configuration.demoMode
            ? DemoMusicService()
            : liveService
    }

    func useDemoMode() {
        musicService = DemoMusicService()
    }

    func useLiveMode() {
        musicService = liveService
    }
}
