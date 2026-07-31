import Combine
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let configuration: AppConfiguration
    let settings: AppSettings
    let sessionStore: SessionStore
    let networkMonitor: NetworkMonitor
    let historyStore: ListeningHistoryStore
    let libraryStore: MusicLibraryStore
    let offlineStore: OfflineTrackStore
    let player: AudioPlayer
    let musicService: any MusicService
    let webAuthService: VKWebAuthService
    @Published private(set) var isRecoveringSession = false
    private struct SessionRecovery {
        let id: UUID
        let task: Task<String, Error>
    }
    private var sessionRecovery: SessionRecovery?
    private var cancellables = Set<AnyCancellable>()
    private var automaticCacheTask: Task<Void, Never>?
    private var pendingAutomaticCacheTrack: Track?

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
        let offlineStore = OfflineTrackStore()
        self.offlineStore = offlineStore
        offlineStore.configureStorage(
            limitGB: settings.offlineStorageLimitGB
        )
        offlineStore.configure(
            accountID: sessionStore.session?.userID
                ?? sessionStore.profile?.id
        )
        let player = AudioPlayer(
            settings: settings,
            historyStore: historyStore,
            userAgent: sessionStore.userAgent
        )
        self.player = player
        offlineStore.configureEvictionProtection { [weak player] in
            player?.currentTrack?.id
        }
        self.webAuthService = VKWebAuthService()

        let client = APIClient(
            baseURL: configuration.vkAPIBaseURL,
            userAgent: sessionStore.userAgent
        )
        let service = VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion,
            initialUserID: sessionStore.session?.userID
                ?? sessionStore.profile?.id
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
        player.configureOfflinePlayback(
            lookup: { [weak offlineStore] track in
                offlineStore?.localURL(for: track)
            },
            invalidate: { [weak offlineStore] track in
                offlineStore?.remove(track)
            },
            markPlayed: { [weak offlineStore] track in
                offlineStore?.markPlayed(track)
            }
        )
        player.configurePlaybackReady { [weak self] track, isOffline in
            guard !isOffline else { return }
            self?.scheduleAutomaticCache(for: track)
            self?.schedulePredictivePreDownload()
        }
        settings.$offlineStorageLimitGB
            .removeDuplicates()
            .sink { [weak offlineStore] limitGB in
                offlineStore?.configureStorage(limitGB: limitGB)
            }
            .store(in: &cancellables)
        settings.$automaticOfflineCacheEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.pendingAutomaticCacheTrack = nil
            }
            .store(in: &cancellables)
    }

    func configureOfflineAccount() {
        let accountID = sessionStore.session?.userID
            ?? sessionStore.profile?.id
        offlineStore.configure(accountID: accountID)
        OfflinePlaylistStore.shared.configure(accountID: accountID)
    }

    func downloadForOffline(
        _ track: Track,
        retention: OfflineTrackRetention = .manual
    ) async throws {
        let refreshed = try await withAuthorizedToken { token in
            try await musicService.refreshedTrack(
                track,
                accessToken: token
            )
        }
        try await offlineStore.download(
            refreshed,
            userAgent: sessionStore.userAgent,
            retention: retention
        )
    }

    private func scheduleAutomaticCache(for track: Track) {
        guard settings.automaticOfflineCacheEnabled,
              networkMonitor.state == .online,
              networkMonitor.transport == .wifi
                || networkMonitor.transport == .wired,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !offlineStore.contains(track) else {
            return
        }
        let estimatedSize = min(
            OfflineTrackStore.maximumTrackSize,
            max(5_000_000, Int64(track.duration * 40_000))
        )
        let remainingSpace = offlineStore.storageLimitBytes
            - offlineStore.totalByteCount
        guard estimatedSize <= remainingSpace else { return }
        pendingAutomaticCacheTrack = track
        guard automaticCacheTask == nil else { return }
        automaticCacheTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let next = pendingAutomaticCacheTrack {
                pendingAutomaticCacheTrack = nil
                guard settings.automaticOfflineCacheEnabled,
                      networkMonitor.state == .online,
                      networkMonitor.transport == .wifi
                        || networkMonitor.transport == .wired,
                      !ProcessInfo.processInfo.isLowPowerModeEnabled else {
                    continue
                }
                do {
                    try await downloadForOffline(
                        next,
                        retention: .automaticCache
                    )
                } catch is CancellationError {
                    break
                } catch {
                    // Automatic caching is opportunistic and must never
                    // interrupt playback with an error.
                }
            }
            automaticCacheTask = nil
        }
    }

    private var predictivePreDownloadTask: Task<Void, Never>?

    private func schedulePredictivePreDownload() {
        guard settings.automaticOfflineCacheEnabled,
              networkMonitor.state == .online,
              (networkMonitor.transport == .wifi
                || networkMonitor.transport == .wired),
              !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return }
        guard let currentIndex = player.currentIndex,
              player.queue.count > 1 else { return }
        predictivePreDownloadTask?.cancel()
        predictivePreDownloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let upcoming = player.queue
                .suffix(from: currentIndex + 1)
                .prefix(5)
            for track in upcoming {
                guard !Task.isCancelled else { break }
                guard !offlineStore.contains(track) else { continue }
                let remaining = offlineStore.storageLimitBytes
                    - offlineStore.totalByteCount
                let est = min(
                    OfflineTrackStore.maximumTrackSize,
                    max(5_000_000, Int64(track.duration * 40_000))
                )
                guard est <= remaining else { break }
                do {
                    try await downloadForOffline(
                        track,
                        retention: .automaticCache
                    )
                } catch is CancellationError {
                    break
                } catch {
                    // Opportunistic — never interrupt playback.
                }
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
        let baselineRevision = sessionStore.sessionRevision

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
            guard sessionStore.sessionRevision == baselineRevision,
                  currentSession == baselineSession else {
                await musicService.configure(
                    userAgent: currentSession.userAgent
                )
                player.configureNetwork(
                    userAgent: currentSession.userAgent
                )
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
                guard sessionStore.sessionRevision == baselineRevision,
                      latestSession == baselineSession else {
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

enum SessionRecoveryDisposition: Equatable {
    case ignore
    case retry
    case requiresLogin

    static func classify(_ error: Error) -> SessionRecoveryDisposition {
        if error is CancellationError {
            return .ignore
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return .requiresLogin
            case let .server(code, _) where code == 5:
                return .requiresLogin
            default:
                return .retry
            }
        }
        if let webError = error as? VKWebAuthError {
            switch webError {
            case .noSession, .rejected:
                return .requiresLogin
            case .invalidResponse:
                return .retry
            }
        }
        return .retry
    }
}
