import Foundation

@MainActor
@Observable
final class AppEnvironment {
    let configuration: AppConfiguration
    let vkIntegration = VKPlaybackIntegration()
    let libraryDownloadJob = LibraryDownloadJob()
    let settings: AppSettings
    let sessionStore: SessionStore
    let networkMonitor: NetworkMonitor
    let historyStore: ListeningHistoryStore
    let libraryStore: MusicLibraryStore
    let homeCatalogStore: HomeCatalogStore
    let likedAlbumsStore: LikedAlbumsStore
    let offlineStore: OfflineTrackStore
    let pinnedMixStore: PinnedMixStore
    let mixFeedbackStore: MixFeedbackStore
    let homePersonalizationStore: HomePersonalizationStore
    let trackShareService: TrackShareService
    let player: AudioPlayer
    let watchRemoteCoordinator: WatchRemoteCoordinator
    let musicService: any MusicService
    let webAuthService: VKWebAuthService
    /// Mix refill — surface a silent filter widen.
    func continuationTracks(_ tracks: [Track]) -> [Track] {
        let outcome = filterMixTracks(tracks, relaxIfEmpty: true)
        if outcome.didRelax {
            mixNotice = L10n.text("mix_filters_relaxed_to_keep_queue")
        }
        return outcome.tracks
    }

    private(set) var isRecoveringSession = false
    /// While a share export is active, offline downloads and automatic
    /// caching are paused and hidden so the share transfer gets bandwidth.
    private(set) var isShareSessionActive = false
    var mixActionError: String?
    /// Informational mix messages (e.g. filters relaxed to keep the queue
    /// alive). Kept apart from `mixActionError` so background refills never
    /// surface as a modal "Playback Error" while playback is fine.
    var mixNotice: String?
    private var snippetTask: Task<Void, Never>?
    private struct SessionRecovery {
        let id: UUID
        let task: Task<String, Error>
    }
    private var sessionRecovery: SessionRecovery?
    private var shareSessionDepth = 0
    @ObservationIgnored private var automaticCacheTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCacheID = UUID()
    @ObservationIgnored private var automaticCacheTrackID: String?
    @ObservationIgnored private var automaticCacheSessionRevision: Int?
    @ObservationIgnored private let cacheNotifications = CacheNotificationRegistrations()
    @ObservationIgnored private var cacheObservation: ObservationLoop.Token?
    @ObservationIgnored private var likeObserver: NSObjectProtocol?
    @ObservationIgnored private let energyMetrics = EnergyMetricsReporter()
    /// The live environment, for App Intents that run inside the app process
    /// (Siri / Shortcuts) and have no view hierarchy to read it from.
    static weak var current: AppEnvironment?
    /// The library-wide walks that more than one screen can ask for.
    private enum RefreshSlot: Hashable {
        case libraryIndex
        case likedAlbums
    }
    private struct RefreshKey: Hashable {
        let slot: RefreshSlot
        let accountRevision: Int
    }
    private var refreshTasks: [RefreshKey: Task<Void, Never>] = [:]
    private var settingsObservation: ObservationLoop.Token?

    init(
        configuration: AppConfiguration = .current,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.configuration = configuration
        self.settings = AppSettings()
        self.sessionStore = SessionStore(keychain: keychain)
        self.networkMonitor = NetworkMonitor()
        self.historyStore = ListeningHistoryStore(accountID: sessionStore.resolvedOfflineAccountID)
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
        let pinnedMixStore = PinnedMixStore()
        pinnedMixStore.configure(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        self.pinnedMixStore = pinnedMixStore
        let mixFeedbackStore = MixFeedbackStore()
        mixFeedbackStore.configure(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        self.mixFeedbackStore = mixFeedbackStore
        let homePersonalizationStore = HomePersonalizationStore()
        homePersonalizationStore.configure(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        self.homePersonalizationStore = homePersonalizationStore
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
        self.webAuthService = VKWebAuthService()

        let client = APIClient(
            baseURL: configuration.vkAPIBaseURL,
            userAgent: sessionStore.userAgent
        )
        let service = VKMusicService(
            client: client,
            apiVersion: configuration.apiVersion,
            initialUserID: sessionStore.resolvedOfflineAccountID,
            initialAccessToken: sessionStore.accessToken
        )
        self.musicService = service
        // One answer for "what belongs in a mix queue": bans + language +
        // familiarity. Must sit after every stored property is set — a
        // `[weak self]` capture before that fails definite initialization.
        player.configureMixTrackFilter { [weak self] tracks in
            guard let self else { return tracks }
            return self.filteredMixTracks(tracks)
        }
        player.configureMixRadioRefill { [weak self, service] seed, mode in
            guard let self else { return [] }
            return try await self.withAuthorizedToken { token in
                try await service.recommendations(
                    seededBy: seed,
                    accessToken: token,
                    shuffle: mode == .moreNovel
                )
            }
        }
        player.configureContinuation { [weak self, service] in
            guard let self else { return [] }
            let remote = try await self.withAuthorizedToken { token in
                try await service.recommendations(accessToken: token)
            }
            return self.filteredMixTracks(remote)
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
        player.noteSessionRotated(revision: sessionStore.sessionRevision)
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
        }
        settingsObservation = ObservationLoop.start { [weak self] in
            guard let self else { return }
            let limitGB = self.settings.offlineStorageLimitGB
            self.offlineStore.configureStorage(limitGB: limitGB)
            let state = self.networkMonitor.state
            if state != .offline {
                self.player.resumePreloading()
            } else {
                self.player.cancelPreloading()
            }
            _ = self.networkMonitor.revision
            self.player.updateNetworkCondition(self.networkMonitor.condition)
        }

        cacheObservation = ObservationLoop.start { [weak self] in
            guard let self else { return }
            let allowed = self.allowsAutomaticCache
            let playing = self.player.isPlaying
            let trackID = self.player.currentTrack?.id
            let revision = self.sessionStore.sessionRevision
            if !allowed || !playing || trackID != self.automaticCacheTrackID
                || revision != self.automaticCacheSessionRevision {
                self.cancelAutomaticCache()
            }
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            cacheNotifications.tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.allowsAutomaticCache else { return }
                    self.cancelAutomaticCache()
                }
            })
        }

        Task {
            await trackShareService.removeStaleExports()
        }

        if !OfflineDownloadsFeature.isEnabled {
            // Vacation-stable build: stop any leftover offline jobs so share
            // and playback are not competing with download workers.
            DownloadCoordinator.shared.cancelAll()
            OfflinePlaylistStore.shared.cancelAllDownloads()
            DownloadCoordinator.shared.unblockQueue()
            cancelAutomaticCache()
        }
        watchRemoteCoordinator.configureControlGate { [weak self] in
            self?.isShareSessionActive == false
        }
        watchRemoteCoordinator.configureLibrary(
            isLiked: { [weak self] track in
                guard let self else { return false }
                return self.libraryStore.isLiked(
                    track,
                    currentUserID: self.sessionStore.resolvedOfflineAccountID
                )
            },
            likeCurrent: { [weak self] track in
                await self?.addToLibraryRemotely(track) ?? false
            },
            unlikeCurrent: { [weak self] track in
                await self?.removeFromLibraryRemotely(track) ?? false
            }
        )
        // The same library actions serve the system Like button (CarPlay,
        // lock screen) as the Watch.
        player.remoteIsLiked = { [weak self] track in
            guard let self else { return false }
            return self.libraryStore.isLiked(
                track,
                currentUserID: self.sessionStore.resolvedOfflineAccountID
            )
        }
        player.remoteSetLiked = { [weak self] track, liked in
            guard let self else { return false }
            return liked
                ? await self.addToLibraryRemotely(track)
                : await self.removeFromLibraryRemotely(track)
        }
        sessionStore.onAccountChange = { [weak self] in
            guard let self else { return }
            for task in self.refreshTasks.values { task.cancel() }
            self.refreshTasks.removeAll()
            self.cancelSessionRecovery()
            self.player.stop()
            self.configureOfflineAccount()
        }
        configureOfflineAccount()
        watchRemoteCoordinator.start()
        vkIntegration.start(environment: self)
        energyMetrics.start()
        Self.current = self
        likeObserver = NotificationCenter.default.addObserver(
            forName: MusicLibraryEvents.didAddTrack,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let track = notification.userInfo?[
                MusicLibraryEvents.trackKey
            ] as? Track else { return }
            MainActor.assumeIsolated {
                self?.downloadLikedTrackIfEnabled(track)
            }
        }
    }

    /// Adds a track to the VK library for a remote control (Watch, car,
    /// lock screen). Already-liked counts as success.
    private func addToLibraryRemotely(_ track: Track) async -> Bool {
        if libraryStore.contains(track) { return true }
        do {
            let added = try await withAuthorizedToken { token in
                try await self.musicService.addToLibrary(
                    track,
                    accessToken: token
                )
            }
            libraryStore.markAdded(source: track, stored: added)
            return true
        } catch {
            return false
        }
    }

    private func removeFromLibraryRemotely(_ track: Track) async -> Bool {
        do {
            let stored = libraryStore.storedTrack(for: track) ?? track
            try await withAuthorizedToken { token in
                try await self.musicService.removeFromLibrary(
                    stored,
                    accessToken: token
                )
            }
            libraryStore.markRemoved(track)
            libraryStore.markRemoved(stored)
            MusicLibraryEvents.postRemoved(stored)
            return true
        } catch {
            return false
        }
    }

    /// "Auto-download likes": a freshly liked track is saved for offline
    /// playback, on Wi-Fi only. Anything else (cellular, a share in
    /// progress, downloads disabled) leaves the like alone.
    private func downloadLikedTrackIfEnabled(_ track: Track) {
        guard settings.autoDownloadLikes,
              OfflineDownloadsFeature.isEnabled,
              !isShareSessionActive,
              networkMonitor.transport == .wifi,
              !offlineStore.contains(track) else { return }
        Task { [weak self] in
            do {
                try await self?.downloadForOffline(track)
            } catch is CancellationError {
                return
            } catch {
                AppLog.shared.failure(.app, "Auto-download liked track", error)
            }
        }
    }

    func configureOfflineAccount() {
        let accountID = sessionStore.resolvedOfflineAccountID
        historyStore.configure(accountID: accountID)
        libraryDownloadJob.configure(accountID: accountID)
        libraryStore.prepare(accountID: accountID)
        likedAlbumsStore.prepare(accountID: accountID)
        homeCatalogStore.prepare(accountID: accountID)
        offlineStore.configure(accountID: accountID)
        OfflinePlaylistStore.shared.configure(accountID: accountID)
        pinnedMixStore.configure(accountID: accountID)
        mixFeedbackStore.configure(accountID: accountID)
        homePersonalizationStore.configure(accountID: accountID)
    }

    /// Walks the whole personal library and rebuilds the liked-track index.
    ///
    /// Both the tab shell and Медиатека used to run this on the same
    /// token-change trigger, so opening the library fired the walk twice and
    /// the shorter of the two overwrote the index. Concurrent callers now
    /// await one shared walk.
    func refreshLibraryIndex() async {
        await coalesced(.libraryIndex) { [self] in
            guard sessionStore.accessToken != nil else { return }
            let refreshID = libraryStore.beginRefresh()
            var collected: [Track] = []
            var offset = 0
            do {
                while !Task.isCancelled {
                    let page = try await withAuthorizedToken { token in
                        try await musicService.library(
                            accessToken: token,
                            offset: offset,
                            count: 100
                        )
                    }
                    collected.append(contentsOf: page.items)
                    guard let next = page.nextOffset, next > offset else {
                        break
                    }
                    offset = next
                }
                try Task.checkCancellation()
                libraryStore.replace(with: collected, refreshID: refreshID)
            } catch {
                return
            }
        }
    }

    /// Loads every followed album for the Albums shelf. Shared for the same
    /// reason as `refreshLibraryIndex()`.
    func refreshLikedAlbums() async {
        await coalesced(.likedAlbums) { [self] in
            likedAlbumsStore.prepare(
                accountID: sessionStore.resolvedOfflineAccountID
            )
            guard sessionStore.accessToken != nil else { return }
            let refreshID = likedAlbumsStore.beginRefresh()
            var collected: [Album] = []
            var offset = 0
            do {
                while !Task.isCancelled {
                    let page = try await withAuthorizedToken { token in
                        try await musicService.likedAlbums(
                            accessToken: token,
                            offset: offset,
                            count: 100
                        )
                    }
                    collected.append(contentsOf: page.items)
                    guard let next = page.nextOffset, next > offset else {
                        break
                    }
                    offset = next
                }
                try Task.checkCancellation()
                likedAlbumsStore.replace(with: collected, refreshID: refreshID)
            } catch {
                return
            }
        }
    }

    /// Runs `operation` once for every caller that asks while it is in
    /// flight. A caller that goes away cannot cancel the shared work — the
    /// stores it fills are shared too, so the second caller adopts the walk
    /// the first one started instead of racing it.
    private func coalesced(
        _ slot: RefreshSlot,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let key = RefreshKey(slot: slot, accountRevision: sessionStore.accountRevision)
        if let inFlight = refreshTasks[key] {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            guard !Task.isCancelled,
                  sessionStore.accountRevision == key.accountRevision else { return }
            await operation()
        }
        refreshTasks[key] = task
        await task.value
        if refreshTasks[key] == task {
            refreshTasks[key] = nil
        }
    }

    func refreshHomeCatalog(force: Bool = false) async {
        homeCatalogStore.prepare(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        guard sessionStore.accessToken != nil,
              homeCatalogStore.shouldRefresh(force: force) else {
            return
        }
        let refreshID = homeCatalogStore.beginRefreshing()
        var recommendations: [Track]?
        var mixes: [MusicMix]?
        var newReleases: [Album]?
        var failures: [String] = []

        // Independent home sources load in parallel — one catalog round-trip
        // still covers mixes + new releases.
        async let recommendationsResult: Result<[Track], Error> = {
            do {
                let value = try await withAuthorizedToken { token in
                    try await musicService.recommendations(accessToken: token)
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }()
        async let snapshotResult: Result<VKCatalogSnapshot, Error> = {
            do {
                let value = try await withAuthorizedToken { token in
                    try await musicService.catalogSnapshot(accessToken: token)
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }()
        switch await recommendationsResult {
        case let .success(value):
            recommendations = value
        case let .failure(error):
            if error is CancellationError {
                homeCatalogStore.cancelRefreshing(refreshID: refreshID)
                return
            }
            failures.append(error.localizedDescription)
        }

        switch await snapshotResult {
        case let .success(snapshot):
            mixes = snapshot.mixes
            newReleases = snapshot.newReleases
        case let .failure(error):
            if error is CancellationError {
                homeCatalogStore.cancelRefreshing(refreshID: refreshID)
                return
            }
            failures.append(error.localizedDescription)
            newReleases = []
        }

        homeCatalogStore.finish(
            recommendations: recommendations,
            mixes: mixes,
            newReleases: newReleases,
            errorMessage: failures.first,
            refreshID: refreshID
        )
    }

    private var resumePlaybackAfterShare = false

    /// Begins a share-export session: pauses offline downloads / auto-cache
    /// and hides those controls until `endShareSession()` balances it out.
    func beginShareSession() {
        shareSessionDepth += 1
        guard shareSessionDepth == 1 else { return }
        isShareSessionActive = true
        cancelAutomaticCache()
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
                    "offline_downloads_are_temporarily_disabled_use_share_instead"
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

    private var allowsAutomaticCache: Bool {
        PlaybackResourcePolicy.allowAutomaticCaching(
            enabled: OfflineDownloadsFeature.isEnabled && settings.automaticOfflineCacheEnabled,
            sharing: isShareSessionActive,
            unmeteredNetwork: networkMonitor.state == .online
                && (networkMonitor.transport == .wifi || networkMonitor.transport == .wired)
        )
    }

    private func cancelAutomaticCache() {
        automaticCacheID = UUID()
        automaticCacheTask?.cancel()
        automaticCacheTask = nil
        automaticCacheTrackID = nil
        automaticCacheSessionRevision = nil
    }

    private func scheduleAutomaticCache(for track: Track) {
        // A skip replaces speculative work. Current and next track share one
        // worker instead of competing with playback through two download loops.
        cancelAutomaticCache()
        guard allowsAutomaticCache else { return }
        let request = automaticCacheID
        let revision = sessionStore.sessionRevision
        automaticCacheTrackID = track.id
        automaticCacheSessionRevision = revision
        automaticCacheTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self else { return }
            defer {
                if automaticCacheID == request { automaticCacheTask = nil }
            }
            guard player.currentTrack?.id == track.id else { return }
            var candidates = [track]
            if let index = player.currentIndex, player.queue.indices.contains(index + 1) {
                let next = player.queue[index + 1]
                if next.id != track.id { candidates.append(next) }
            }
            for candidate in candidates {
                guard !Task.isCancelled, automaticCacheID == request,
                      sessionStore.sessionRevision == revision,
                      allowsAutomaticCache, player.isPlaying,
                      player.currentTrack?.id == track.id else { return }
                guard !offlineStore.contains(candidate) else { continue }
                let estimate = PlaybackResourcePolicy.automaticCacheSizeEstimate(duration: candidate.duration)
                guard estimate <= offlineStore.storageLimitBytes - offlineStore.totalByteCount else { return }
                do {
                    try await downloadForOffline(candidate, retention: .automaticCache)
                } catch is CancellationError {
                    return
                } catch {
                    // Opportunistic failures must never interrupt playback.
                }
            }
        }
    }

    func withAuthorizedToken<Value>(
        _ operation: (String) async throws -> Value
    ) async throws -> Value {
        try await sessionStore.withAuthorizedToken(
            recoverSession: { try await self.recoverSession() },
            operation: operation
        )
    }

    func recoverSession() async throws -> String {
        if let sessionRecovery {
            return try await sessionRecovery.task.value
        }
        guard let baselineSession = sessionStore.session,
              let cookie = baselineSession.refreshCookie,
              let webUserAgent = baselineSession.webUserAgent else {
            AppLog.shared.error(.session, "Session recovery missing refresh material")
            throw APIError.unauthorized
        }
        let baselineRevision = sessionStore.sessionRevision
        AppLog.shared.info(
            .session,
            "Session recovery started revision=\(baselineRevision)"
        )

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
                // Every stream URL already queued was signed by the token
                // this exchange just replaced, so they are all dead. Say so
                // now rather than letting the player discover it one 404 at
                // a time, track by track.
                player.noteSessionRotated(
                    revision: sessionStore.sessionRevision
                )
                AppLog.shared.info(
                    .session,
                    "Session recovery succeeded userID=\(profile.id)"
                )
                return result.accessToken
            } catch {
                AppLog.shared.error(
                    .session,
                    "Session recovery failed: \(AppLogRedaction.redact(error.localizedDescription))"
                )
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

    // MARK: - Mix experience (global)

    /// Language / familiarity / bans for seed and bootstrap queues.
    /// Falls back to the ban-only pool when filters would empty it so a
    /// cold start always has something to play.
    func filteredMixTracks(_ tracks: [Track]) -> [Track] {
        let outcome = filterMixTracks(tracks, relaxIfEmpty: true)
        if outcome.didRelax {
            mixNotice = L10n.text("mix_filters_relaxed_to_keep_queue")
        }
        return outcome.tracks
    }

    /// Same filters without the silent widen — used when the listener
    /// just tightened a chip and expects the queue to shrink.
    func filterMixTracks(
        _ tracks: [Track],
        relaxIfEmpty: Bool
    ) -> MixFilterOutcome {
        let historyArtists = Set(
            historyStore.entries
                .prefix(MixListeningHistoryWindow.familiarity)
                .map(\.track.artist)
        )
        let afterFeedback = mixFeedbackStore.filtering(tracks)
        let language = settings.mixLanguagePreference
        if relaxIfEmpty {
            return MixQueueFilter.applyAllowingFallback(
                afterFeedback,
                language: language,
                familiarity: settings.mixFamiliarityPreference,
                historyArtists: historyArtists
            )
        }
        return MixFilterOutcome(
            tracks: MixQueueFilter.applyStrict(
                afterFeedback,
                language: language,
                familiarity: settings.mixFamiliarityPreference,
                historyArtists: historyArtists
            ),
            didRelax: false
        )
    }

    /// Re-run mix filters on the unplayed suffix of the live mix queue.
    /// Tightening drops non-matching tracks immediately; if that would
    /// empty the suffix we keep it and surface that the filters relaxed.
    /// Full recovery from an unfiltered baseline is owned by the mix
    /// hub's `refilterLoadedTracks`.
    func reapplyMixFiltersToPlayingQueue() {
        guard case .mix = player.queueSource,
              let index = player.currentIndex,
              player.queue.indices.contains(index) else { return }
        let upcoming = Array(player.queue.suffix(from: index + 1))
        guard !upcoming.isEmpty else { return }
        let outcome = filterMixTracks(upcoming, relaxIfEmpty: true)
        player.replaceUpcoming(with: outcome.tracks)
        if outcome.didRelax {
            mixNotice = L10n.text("mix_filters_relaxed_to_keep_queue")
        }
    }

    func dislike(_ track: Track, includeArtist: Bool) {
        mixFeedbackStore.ban(track, includeArtist: includeArtist)
        if player.currentTrack?.id == track.id {
            player.skipAndDropCurrent()
        }
        if case .mix = player.queueSource,
           let index = player.currentIndex,
           player.queue.indices.contains(index) {
            let upcoming = Array(player.queue.suffix(from: index + 1))
            player.replaceUpcoming(with: filteredMixTracks(upcoming))
        }
        Haptics.selection()
    }

    func startMixFromTrack(_ track: Track) async {
        mixActionError = nil
        do {
            let remote = try await withAuthorizedToken { token in
                try await musicService.recommendations(
                    seededBy: track,
                    accessToken: token,
                    shuffle: false
                )
            }
            var queue = [track]
            var known: Set<String> = [track.id]
            for item in filteredMixTracks(remote)
            where known.insert(item.id).inserted {
                queue.append(item)
            }
            let stream = RadioRecommendationCursor(
                seedTracks: [track] + queue,
                knownTracks: queue
            )
            let title = L10n.format("mix_based_on_0", track.title)
            // The launch that started this may have been cancelled while
            // the request was in flight — a later reply must not seize a
            // queue the listener has already replaced.
            guard !Task.isCancelled else { return }
            player.play(
                track,
                in: queue,
                continuation: { [weak self] in
                    guard let self else { return [] }
                    let more = try await self.withAuthorizedToken { token in
                        try await stream.next(
                            accessToken: token,
                            musicService: self.musicService
                        )
                    }
                    return self.continuationTracks(more)
                },
                source: .seedMix(trackID: track.id, title: title)
            )
            player.rerankUpcomingMix(
                mode: .closerToSeed,
                seed: track,
                historyArtists: Set(
                    historyStore.entries.prefix(MixListeningHistoryWindow.ranking).map(\.track.artist)
                )
            )
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            mixActionError = error.localizedDescription
        }
    }

    func startMixFromMyMusic() async {
        mixActionError = nil
        do {
            let page = try await withAuthorizedToken { token in
                try await musicService.library(
                    accessToken: token,
                    offset: 0,
                    count: 80
                )
            }
            let recs = try await withAuthorizedToken { token in
                try await musicService.recommendations(accessToken: token)
            }
            let queue = filteredMixTracks(
                MixSeedRadio.blend(
                    seeds: page.items,
                    recommendations: recs
                )
            )
            guard let first = queue.first else {
                mixActionError = L10n.text(
                    "could_not_build_a_mix_from_your_library"
                )
                return
            }
            let stream = RadioRecommendationCursor(
                seedTracks: page.items + recs,
                knownTracks: queue
            )
            // The launch that started this may have been cancelled while
            // the request was in flight — a later reply must not seize a
            // queue the listener has already replaced.
            guard !Task.isCancelled else { return }
            player.play(
                first,
                in: queue,
                continuation: { [weak self] in
                    guard let self else { return [] }
                    let more = try await self.withAuthorizedToken { token in
                        try await stream.next(
                            accessToken: token,
                            musicService: self.musicService
                        )
                    }
                    return self.continuationTracks(more)
                },
                source: .myMusicMix(title: L10n.text("mix_from_my_music"))
            )
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            mixActionError = error.localizedDescription
        }
    }

    /// The personal station, or the listener's own library when the
    /// catalog has not produced one yet.
    func startPersonalStation(in mixes: [MusicMix]) async {
        var catalog = mixes
        if catalog.isEmpty {
            await refreshHomeCatalog()
            catalog = homeCatalogStore.mixes
        }
        if let personal = catalog.first(where: { $0.id == MusicMix.common.id }) {
            await startCatalogMix(personal)
        } else {
            await startMixFromMyMusic()
        }
    }

    /// A mood chip launches the VK vibe shelf whose title matches it best,
    /// and falls back to the personal mix when no shelf does.
    func startMoodStation(
        _ mood: MixMoodPreference,
        in mixes: [MusicMix]
    ) async {
        guard !Task.isCancelled else { return }
        settings.mixMoodPreference = mood
        var catalog = mixes
        if catalog.isEmpty {
            await refreshHomeCatalog()
            catalog = homeCatalogStore.mixes
        }
        guard !Task.isCancelled else { return }
        let scored = catalog.compactMap { mix -> (MusicMix, Int)? in
            // Mood tiles carry their tuning in `streamOptions` and often
            // have no shelf title, so match on all three.
            let haystack = [mix.sectionTitle, mix.title, mix.streamOptions]
                .compactMap { $0 }
                .joined(separator: " ")
            guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let score = MixQueueFilter.shelfMoodMatchScore(
                haystack,
                mood: mood
            )
            guard score > 0 else { return nil }
            return (mix, score + (mix.streamOptions == nil ? 0 : 5))
        }
        if let best = scored.max(by: { $0.1 < $1.1 })?.0 {
            await startCatalogMix(best)
        } else {
            // Say so: tapping «Грустное» and silently getting the generic
            // mix reads as a broken button.
            mixNotice = L10n.format("mix.mood_fallback", mood.title)
            await startPersonalStation(in: catalog)
        }
    }

    /// Radio for one artist. Tapping an artist bubble used to call
    /// `startMixFromMyMusic()`, which played everything and honoured
    /// nothing about who was tapped.
    ///
    /// Resolution order: VK's artist id when `audio.searchArtists` can
    /// match the name, then the most recent track we hold by them as a
    /// recommendation seed, then a plain search. Every branch stays about
    /// this artist — none of them fall back to the generic library mix.
    func startMixFromArtist(named name: String, seed: Track?) async {
        mixActionError = nil
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            let tracks = try await artistTracks(for: query)
            guard !Task.isCancelled else { return }
            let cleaned = filteredMixTracks(tracks)
            guard let first = cleaned.first else {
                if let seed {
                    await startMixFromTrack(seed)
                } else {
                    mixActionError = L10n.format(
                        "could_not_start_artist_0",
                        query
                    )
                }
                return
            }
            let stream = RadioRecommendationCursor(
                seedTracks: cleaned,
                knownTracks: cleaned
            )
            // The launch that started this may have been cancelled while
            // the request was in flight — a later reply must not seize a
            // queue the listener has already replaced.
            guard !Task.isCancelled else { return }
            player.play(
                first,
                in: cleaned,
                continuation: { [weak self] in
                    guard let self else { return [] }
                    let more = try await self.withAuthorizedToken { token in
                        try await stream.next(
                            accessToken: token,
                            musicService: self.musicService
                        )
                    }
                    return self.continuationTracks(more)
                },
                source: .artistMix(
                    named: query,
                    title: L10n.format("artist_radio_0", query)
                )
            )
            // Keeps the upcoming queue leaning towards the artist that was
            // tapped instead of drifting into general recommendations.
            player.rerankUpcomingMix(
                mode: .closerToSeed,
                seed: first,
                historyArtists: Set(
                    historyStore.entries.prefix(MixListeningHistoryWindow.ranking).map(\.track.artist)
                )
            )
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            if let seed {
                await startMixFromTrack(seed)
            } else {
                mixActionError = error.localizedDescription
            }
        }
    }

    private func artistTracks(for query: String) async throws -> [Track] {
        let candidates = try await withAuthorizedToken { token in
            try await musicService.searchArtists(
                query: query,
                accessToken: token,
                offset: 0,
                count: 8
            )
        }
        if let artist = VKArtistMatch.best(in: candidates, named: query) {
            let page = try await withAuthorizedToken { token in
                try await musicService.artistTracks(
                    artistID: artist.id,
                    accessToken: token,
                    offset: 0,
                    count: 50
                )
            }
            if !page.items.isEmpty { return page.items }
        }
        let search = try await withAuthorizedToken { token in
            try await musicService.search(
                query: query,
                accessToken: token,
                offset: 0,
                count: 50
            )
        }
        return search.items
    }

    func startCatalogMix(_ mix: MusicMix) async {
        mixActionError = nil
        do {
            let bootstrap = try await withAuthorizedToken { token in
                try await musicService.mixTracksBootstrap(
                    mix,
                    accessToken: token
                )
            }
            let cleaned = filteredMixTracks(bootstrap)
            guard let first = cleaned.first else {
                mixActionError = L10n.text("the_mix_is_empty_for_now")
                return
            }
            let cursor = MixTrackContinuationCursor(mix: mix)
            // The launch that started this may have been cancelled while
            // the request was in flight — a later reply must not seize a
            // queue the listener has already replaced.
            guard !Task.isCancelled else { return }
            player.play(
                first,
                in: cleaned,
                continuation: { [weak self] in
                    guard let self else { return [] }
                    let more = try await self.withAuthorizedToken { token in
                        try await cursor.next(
                            accessToken: token,
                            musicService: self.musicService
                        )
                    }
                    return self.continuationTracks(more)
                },
                source: .catalogMix(mix)
            )
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            mixActionError = error.localizedDescription
        }
    }

    /// Hold-to-preview style snippet: jump into the track and stop ~32s later.
    func previewSnippet(_ track: Track) async {
        snippetTask?.cancel()
        let start = SnippetPreviewPolicy.startOffset(for: track.duration)
        player.play(track, in: [track])
        snippetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.player.seek(to: start)
            }
            try? await Task.sleep(
                nanoseconds: SnippetPreviewPolicy.windowNanoseconds
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.player.currentTrack?.id == track.id else { return }
                self?.player.pause()
            }
        }
        Haptics.selection()
    }
}

enum SnippetPreviewPolicy {
    static let windowSeconds: TimeInterval = 32
    static var windowNanoseconds: UInt64 {
        UInt64(windowSeconds * 1_000_000_000)
    }

    static func startOffset(for duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 20 else { return 0 }
        let ideal = duration * 0.35
        let maxStart = max(0, duration - windowSeconds - 1)
        return min(max(ideal, 0), maxStart)
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

/// Main-actor owned; releases process-wide observers when the environment dies.
private final class CacheNotificationRegistrations: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
