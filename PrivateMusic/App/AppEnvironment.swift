import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let settings: AppSettings
    let sessionStore: SessionStore
    let networkMonitor: NetworkMonitor
    let historyStore: ListeningHistoryStore
    let libraryStore: MusicLibraryStore
    let player: AudioPlayer
    let musicService: any MusicService
    let webAuthService: VKWebAuthService
    @Published private(set) var isRecoveringSession = false
    private struct SessionRecovery {
        let id: UUID
        let task: Task<String, Error>
    }
    private var sessionRecovery: SessionRecovery?

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.configuration = configuration
        self.settings = AppSettings()
        self.sessionStore = SessionStore(keychain: keychain)
        self.networkMonitor = NetworkMonitor()
        self.historyStore = ListeningHistoryStore()
        self.libraryStore = MusicLibraryStore()
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
        player.configureContinuation { [weak self, service] in
            guard let self else { return [] }
            return try await self.withAuthorizedToken { token in
                try await service.recommendations(accessToken: token)
            }
        }
        player.configureStreamRefresh { [weak self, service] track in
            guard let self else { throw CancellationError() }
            return try await self.withAuthorizedToken { token in
                try await service.refreshedTrack(
                    track,
                    accessToken: token
                )
            }
        }
    }

    func withAuthorizedToken<Value>(
        _ operation: (String) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let attemptedToken = sessionStore.accessToken else {
            throw APIError.unauthorized
        }

        do {
            return try await operation(attemptedToken)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            try Task.checkCancellation()
        }

        if let latestToken = sessionStore.accessToken,
           latestToken != attemptedToken {
            do {
                return try await operation(latestToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error == .unauthorized {
                try Task.checkCancellation()
            }
        }

        let refreshedToken = try await recoverSession()
        try Task.checkCancellation()

        // A web exchange may legitimately return the same token with refreshed
        // cookies. The rejected operation still gets one clean retry.
        return try await operation(refreshedToken)
    }

    func recoverSession() async throws -> String {
        if let sessionRecovery {
            return try await sessionRecovery.task.value
        }
        guard let baselineSession = sessionStore.session,
              let cookie = baselineSession.refreshCookie,
              let webUserAgent = baselineSession.webUserAgent else {
            throw APIError.unauthorized
        }

        let recoveryID = UUID()
        isRecoveringSession = true
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let result = try await webAuthService.exchange(
                cookieHeader: cookie,
                webUserAgent: webUserAgent
            )
            try Task.checkCancellation()

            // Never let an exchange started for an old account overwrite a
            // logout, a new login or a token rotated by another workflow.
            guard let currentSession = sessionStore.session else {
                throw CancellationError()
            }
            guard currentSession == baselineSession else {
                return currentSession.accessToken
            }

            await musicService.configure(userAgent: result.apiUserAgent)
            player.configureNetwork(userAgent: result.apiUserAgent)
            do {
                let profile = try await musicService.profile(
                    accessToken: result.accessToken
                )
                try Task.checkCancellation()

                guard let latestSession = sessionStore.session else {
                    throw CancellationError()
                }
                guard latestSession == baselineSession else {
                    await musicService.configure(
                        userAgent: latestSession.userAgent
                    )
                    player.configureNetwork(
                        userAgent: latestSession.userAgent
                    )
                    return latestSession.accessToken
                }

                try sessionStore.updateWebSession(result, profile: profile)
                return result.accessToken
            } catch {
                let retainedUserAgent = sessionStore.session?.userAgent
                await musicService.configure(userAgent: retainedUserAgent)
                player.configureNetwork(userAgent: retainedUserAgent)
                throw error
            }
        }
        sessionRecovery = SessionRecovery(id: recoveryID, task: task)
        defer {
            if sessionRecovery?.id == recoveryID {
                sessionRecovery = nil
                isRecoveringSession = false
            }
        }
        return try await task.value
    }

    func cancelSessionRecovery() {
        sessionRecovery?.task.cancel()
        sessionRecovery = nil
        isRecoveringSession = false
    }
}
