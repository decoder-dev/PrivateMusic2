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
    let homeCatalogStore: HomeCatalogStore
    let likedAlbumsStore: LikedAlbumsStore
    let offlineStore: OfflineTrackStore
    let trackShareService: TrackShareService
    let player: AudioPlayer
    let watchRemoteCoordinator: WatchRemoteCoordinator
    let musicService: any MusicService
    let webAuthService: any VKWebAuthExchanging
    let refreshController: HomeCatalogRefreshController
    @Published private(set) var isRecoveringSession = false
    /// While a share export is active, offline downloads and automatic
    /// caching are paused and hidden so the share transfer gets bandwidth.
    @Published private(set) var isShareSessionActive = false
    private var shareSessionDepth = 0
    private var cancellables = Set<AnyCancellable>()
    private var automaticCacheTask: Task<Void, Never>?
    private var pendingAutomaticCacheTrack: Track?

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore(),
        musicService: (any MusicService)? = nil,
        webAuthService: (any VKWebAuthExchanging)? = nil
    ) {
        self.configuration = configuration
        self.settings = AppSettings()
        self.sessionStore = SessionStore(keychain: keychain)
        self.networkMonitor = NetworkMonitor()
        self.historyStore = ListeningHistoryStore()
        self.libraryStore = MusicLibraryStore()
        self.homeCatalogStore = HomeCatalogStore()
        self.likedAlbumsStore = LikedAlbumsStore()
        let trackShareService = TrackShareService()
        self.trackShareService = trackShareService

        let offlineStore = OfflineTrackStore(
            downloadService: trackShareService
        )
        self.offlineStore = offlineStore
        offlineStore.configureStorage(
            limitGB: settings.offlineStorageLimitGB
        )
        offlineStore.configure(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        let player = AudioPlayer(
            settings: settings,
            historyStore: historyStore,
            userAgent: sessionStore.userAgent
        )
        self.player = player
        let watchRemoteCoordinator = WatchRemoteCoordinator(player: player)
        self.watchRemoteCoordinator = watchRemoteCoordinator
        offlineStore.configureEvictionProtection { [weak player] in
            player?.currentTrack?.id
        }
        self.webAuthService = webAuthService ?? VKWebAuthService()

        let client = APIClient(
            baseURL: configuration.vkAPIBaseURL,
            userAgent: sessionStore.userAgent
        )
        let service = musicService ?? VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion,
            initialUserID: sessionStore.resolvedOfflineAccountID
        )
        self.musicService = service
        let refreshController = HomeCatalogRefreshController(
            sessionStore: sessionStore,
            musicService: service,
            webAuthService: self.webAuthService,
            homeCatalogStore: homeCatalogStore,
            onUserAgentChanged: { [weak player] userAgent in
                player?.configureNetwork(userAgent: userAgent)
            }
        )
        self.refreshController = refreshController
        refreshController.$isRecoveringSession
            .sink { [weak self] value in
                self?.isRecoveringSession = value
            }
            .store(in: &cancellables)
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
        player.configurePreloading(
            isAllowed: { [weak self] in
                guard let self else { return false }
                // Keep next-track warm on cellular / constrained links —
                // cold opens are a common skip trigger on flaky networks.
                return !self.isShareSessionActive
                    && self.networkMonitor.state != .offline
            },
            artworkPrefetch: { tracks in
                // One size covers mini player / rows; full-screen artwork loads
                // on demand through the shared cache when PlayerView appears.
                for track in tracks {
                    guard !Task.isCancelled else { return }
                    await ArtworkImageCache.shared.prefetch(
                        url: track.artworkURL,
                        maxPixelSize: 512
                    )
                }
            }
        )
        player.configurePlaybackReady { [weak self] track, isOffline in
            guard OfflineDownloadsFeature.isEnabled else { return }
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
        networkMonitor.$state
            .removeDuplicates()
            .sink { [weak player] state in
                // Restart preloads whenever the network is usable again —
                // including constrained cellular, not only unconstrained wifi.
                if state != .offline {
                    player?.resumePreloading()
                } else {
                    player?.cancelPreloading()
                }
            }
            .store(in: &cancellables)

        Task {
            await trackShareService.removeStaleExports()
        }

        if !OfflineDownloadsFeature.isEnabled {
            // Vacation-stable build: stop any leftover offline jobs so share
            // and playback are not competing with download workers.
            DownloadCoordinator.shared.cancelAll()
            OfflinePlaylistStore.shared.cancelAllDownloads()
            DownloadCoordinator.shared.unblockQueue()
            pendingAutomaticCacheTrack = nil
            automaticCacheTask?.cancel()
            automaticCacheTask = nil
            predictivePreDownloadTask?.cancel()
            predictivePreDownloadTask = nil
        }
        watchRemoteCoordinator.configureControlGate { [weak self] in
            self?.isShareSessionActive == false
        }
        watchRemoteCoordinator.start()
    }

    func configureOfflineAccount() {
        let accountID = sessionStore.resolvedOfflineAccountID
        offlineStore.configure(accountID: accountID)
        OfflinePlaylistStore.shared.configure(accountID: accountID)
    }

    func refreshHomeCatalog(force: Bool = false) async {
        await refreshController.refreshHomeCatalog(force: force)
    }

    private var resumePlaybackAfterShare = false

    /// Begins a share-export session: pauses offline downloads / auto-cache
    /// and hides those controls until `endShareSession()` balances it out.
    func beginShareSession() {
        shareSessionDepth += 1
        guard shareSessionDepth == 1 else { return }
        isShareSessionActive = true
        pendingAutomaticCacheTrack = nil
        automaticCacheTask?.cancel()
        automaticCacheTask = nil
        predictivePreDownloadTask?.cancel()
        predictivePreDownloadTask = nil
        DownloadCoordinator.shared.cancelAll()
        player.cancelPreloading()
        // Free media services for HLS demux / AVAssetReader. Without this,
        // stitched MPEG-TS often fails with HLS-SOURCE-11828.
        resumePlaybackAfterShare = player.isPlaying
        if resumePlaybackAfterShare {
            player.pauseForShareExport()
        }
    }

    func endShareSession() {
        guard shareSessionDepth > 0 else { return }
        shareSessionDepth -= 1
        guard shareSessionDepth == 0 else { return }
        isShareSessionActive = false
        DownloadCoordinator.shared.unblockQueue()
        if resumePlaybackAfterShare {
            resumePlaybackAfterShare = false
            player.resume()
        }
        player.resumePreloading()
    }

    /// Prepares a shareable audio file, preferring the already-downloaded
    /// local copy (works offline and without a token). A remote URL is only
    /// touched after a local copy is ruled out, and it is always refreshed
    /// right before the export.
    func prepareSharePayload(
        for track: Track,
        progress: TrackExportProgressHandler? = nil
    ) async throws -> TrackSharePayload {
        progress?(.resolvingSource)
        try Task.checkCancellation()

        if let localURL = offlineStore.localURL(for: track) {
            return try await trackShareService.payloadFromLocalFile(
                localURL,
                track: track,
                requiresMP3: false,
                progress: progress
            )
        }

        let refreshed = try await withAuthorizedToken { token in
            try await musicService.refreshedTrack(
                track,
                accessToken: token
            )
        }
        try Task.checkCancellation()

        return try await trackShareService.preparePayload(
            for: refreshed,
            userAgent: sessionStore.userAgent,
            requiresMP3: false,
            progress: progress
        )
    }

    func removeSharePayload(_ payload: TrackSharePayload) async {
        await trackShareService.removeExportedFile(payload)
    }

    func downloadForOffline(
        _ track: Track,
        retention: OfflineTrackRetention = .manual
    ) async throws {
        guard OfflineDownloadsFeature.isEnabled else {
            throw APIError.server(
                code: 503,
                message: L10n.text(
                    "Офлайн-загрузки временно отключены. Используйте «Поделиться»."
                )
            )
        }
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
        guard OfflineDownloadsFeature.isEnabled,
              !isShareSessionActive,
              settings.automaticOfflineCacheEnabled,
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
                guard !isShareSessionActive,
                      settings.automaticOfflineCacheEnabled,
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
        guard OfflineDownloadsFeature.isEnabled,
              !isShareSessionActive,
              settings.automaticOfflineCacheEnabled,
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
        try await refreshController.withAuthorizedToken(operation)
    }

    func recoverSession() async throws -> String {
        try await refreshController.recoverSession()
    }

    func cancelSessionRecovery() {
        refreshController.cancelSessionRecovery()
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
