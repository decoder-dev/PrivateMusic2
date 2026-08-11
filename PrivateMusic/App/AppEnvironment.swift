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
    let pinnedMixStore: PinnedMixStore
    let mixFeedbackStore: MixFeedbackStore
    let trackShareService: TrackShareService
    let player: AudioPlayer
    let watchRemoteCoordinator: WatchRemoteCoordinator
    let musicService: any MusicService
    let webAuthService: VKWebAuthService
    @Published private(set) var isRecoveringSession = false
    /// While a share export is active, offline downloads and automatic
    /// caching are paused and hidden so the share transfer gets bandwidth.
    @Published private(set) var isShareSessionActive = false
    @Published var mixActionError: String?
    private var snippetTask: Task<Void, Never>?
    private struct SessionRecovery {
        let id: UUID
        let task: Task<String, Error>
    }
    private var sessionRecovery: SessionRecovery?
    private var shareSessionDepth = 0
    private var cancellables = Set<AnyCancellable>()
    private var automaticCacheTask: Task<Void, Never>?
    private var pendingAutomaticCacheTrack: Track?
    /// The library-wide walks that more than one screen can ask for.
    private enum RefreshSlot: Hashable {
        case libraryIndex
        case likedAlbums
    }
    private var refreshTasks: [RefreshSlot: Task<Void, Never>] = [:]

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
        let player = AudioPlayer(
            settings: settings,
            historyStore: historyStore,
            userAgent: sessionStore.userAgent
        )
        player.configureMixTrackFilter { [weak mixFeedbackStore] tracks in
            mixFeedbackStore?.filtering(tracks) ?? tracks
        }
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
            initialUserID: sessionStore.resolvedOfflineAccountID
        )
        self.musicService = service
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
        watchRemoteCoordinator.configureLibrary(
            isLiked: { [weak self] track in
                guard let self else { return false }
                return self.libraryStore.isLiked(
                    track,
                    currentUserID: self.sessionStore.resolvedOfflineAccountID
                )
            },
            likeCurrent: { [weak self] track in
                guard let self else { return false }
                if self.libraryStore.contains(track) { return true }
                do {
                    let added = try await self.withAuthorizedToken { token in
                        try await self.musicService.addToLibrary(
                            track,
                            accessToken: token
                        )
                    }
                    self.libraryStore.markAdded(source: track, stored: added)
                    return true
                } catch {
                    return false
                }
            }
        )
        watchRemoteCoordinator.start()
    }

    func configureOfflineAccount() {
        let accountID = sessionStore.resolvedOfflineAccountID
        offlineStore.configure(accountID: accountID)
        OfflinePlaylistStore.shared.configure(accountID: accountID)
        pinnedMixStore.configure(accountID: accountID)
        mixFeedbackStore.configure(accountID: accountID)
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
                for _ in 0..<10 {
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
                for _ in 0..<10 {
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
        if let inFlight = refreshTasks[slot] {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in await operation() }
        refreshTasks[slot] = task
        await task.value
        if refreshTasks[slot] == task {
            refreshTasks[slot] = nil
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
        var playlists: [Playlist]?
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
        // «Ваши плейлисты» on the home screen is the same list as the
        // library shelf, so it asks for a full page, collapses the
        // duplicated system playlist and drops the followed releases the
        // Albums shelf owns the same way.
        let playlistOwnerID = sessionStore.session?.userID
        let followedAlbumIdentities = Set(
            likedAlbumsStore.albums.map(\.compositeID)
        )
        async let playlistsResult: Result<[Playlist], Error> = {
            do {
                let value = try await withAuthorizedToken { token in
                    let page = try await musicService.playlists(
                        accessToken: token,
                        offset: 0,
                        count: LibraryPlaylistPagePolicy.pageSize
                    )
                    return page.items
                }
                return .success(
                    LibraryPlaylistShelfPolicy.normalized(
                        value,
                        ownerID: playlistOwnerID,
                        followedAlbumIdentities: followedAlbumIdentities
                    )
                )
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

        switch await playlistsResult {
        case let .success(value):
            playlists = value
        case let .failure(error):
            if error is CancellationError {
                homeCatalogStore.cancelRefreshing(refreshID: refreshID)
                return
            }
            failures.append(error.localizedDescription)
        }

        homeCatalogStore.finish(
            recommendations: recommendations,
            mixes: mixes,
            playlists: playlists,
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

    // MARK: - Mix experience (global)

    func filteredMixTracks(_ tracks: [Track]) -> [Track] {
        let historyArtists = Set(
            historyStore.entries.prefix(80).map(\.track.artist)
        )
        let afterFeedback = mixFeedbackStore.filtering(tracks)
        let filtered = MixQueueFilter.apply(
            afterFeedback,
            language: settings.mixLanguagePreference,
            familiarity: settings.mixFamiliarityPreference,
            historyArtists: historyArtists
        )
        // Never empty a seed queue because filters were too strict.
        return filtered.isEmpty ? afterFeedback : filtered
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
            let stream = SelenaRecommendationCursor(
                seedTracks: [track] + queue,
                knownTracks: queue
            )
            let title = L10n.format("Микс по «%@»", track.title)
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
                    return self.filteredMixTracks(more)
                },
                source: .mix(title: title)
            )
            player.rerankUpcomingMix(
                mode: .closerToSeed,
                seed: track,
                historyArtists: Set(
                    historyStore.entries.prefix(40).map(\.track.artist)
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
            let blended = filteredMixTracks(
                MixSeedRadio.blend(
                    seeds: page.items,
                    recommendations: recs
                )
            )
            guard let first = blended.first else {
                mixActionError = L10n.text(
                    "Не удалось собрать микс по медиатеке"
                )
                return
            }
            let stream = SelenaRecommendationCursor(
                seedTracks: page.items + recs,
                knownTracks: blended
            )
            player.play(
                first,
                in: blended,
                continuation: { [weak self] in
                    guard let self else { return [] }
                    let more = try await self.withAuthorizedToken { token in
                        try await stream.next(
                            accessToken: token,
                            musicService: self.musicService
                        )
                    }
                    return self.filteredMixTracks(more)
                },
                source: .mix(title: L10n.text("Микс по моей музыке"))
            )
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            mixActionError = error.localizedDescription
        }
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
                mixActionError = L10n.text("Микс пока пуст")
                return
            }
            let cursor = MixTrackContinuationCursor(mix: mix)
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
                    return self.filteredMixTracks(more)
                },
                source: .mix(title: mix.title)
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
