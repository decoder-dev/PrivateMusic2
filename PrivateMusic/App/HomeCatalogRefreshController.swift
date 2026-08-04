import Combine
import Foundation

/// Owns VK access-token authorization, coalesced session recovery, and the
/// concurrent home-catalog refresh (recommendations, mixes/new releases,
/// playlists).
///
/// This is split out of `AppEnvironment` so the refresh/parallelism/session
/// coalescing behavior can be unit tested without constructing the rest of
/// the app's object graph (`AudioPlayer`, `WatchRemoteCoordinator`, offline
/// stores, ...). `AppEnvironment` owns one instance and forwards its public
/// `withAuthorizedToken` / `recoverSession` / `refreshHomeCatalog` API to it,
/// so there is still a single source of truth for this logic.
@MainActor
final class HomeCatalogRefreshController: ObservableObject {
    private struct SessionRecovery {
        let id: UUID
        let task: Task<String, Error>
    }

    @Published private(set) var isRecoveringSession = false

    private let sessionStore: SessionStore
    private let musicService: any MusicService
    private let webAuthService: any VKWebAuthExchanging
    private let homeCatalogStore: HomeCatalogStore
    /// Mirrors a refreshed API user agent onto the audio player's network
    /// stack. Kept as a closure (rather than an `AudioPlayer` reference) so
    /// this controller has no dependency on AVFoundation/playback.
    private let onUserAgentChanged: (String?) -> Void
    private var sessionRecovery: SessionRecovery?

    init(
        sessionStore: SessionStore,
        musicService: any MusicService,
        webAuthService: any VKWebAuthExchanging,
        homeCatalogStore: HomeCatalogStore,
        onUserAgentChanged: @escaping (String?) -> Void
    ) {
        self.sessionStore = sessionStore
        self.musicService = musicService
        self.webAuthService = webAuthService
        self.homeCatalogStore = homeCatalogStore
        self.onUserAgentChanged = onUserAgentChanged
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

        // Independent sections load concurrently instead of one after
        // another. `withAuthorizedToken` coalesces any 401-triggered
        // session recovery across all three on the main actor, so a stale
        // token during a refresh still only starts one web-token exchange
        // (see `recoverSession()`), not one per section.
        async let recommendationsResult = withAuthorizedToken { token in
            try await self.musicService.recommendations(accessToken: token)
        }
        async let catalogSectionsResult = withAuthorizedToken { token in
            try await self.musicService.catalogSections(accessToken: token)
        }
        async let playlistsResult = withAuthorizedToken { token in
            let page = try await self.musicService.playlists(
                accessToken: token,
                offset: 0,
                count: 30
            )
            return page.items
        }

        var recommendations: [Track]?
        var mixes: [MusicMix]?
        var playlists: [Playlist]?
        var newReleases: [Album]?
        var failures: [String] = []

        do {
            recommendations = try await recommendationsResult
        } catch is CancellationError {
            homeCatalogStore.cancelRefreshing(refreshID: refreshID)
            return
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            let sections = try await catalogSectionsResult
            mixes = sections.mixes
            newReleases = sections.newReleases
        } catch is CancellationError {
            homeCatalogStore.cancelRefreshing(refreshID: refreshID)
            return
        } catch {
            // Mixes and new releases now share one request. A failure is a
            // real catalog failure for mixes, but new releases stays a
            // speculative endpoint (VK does not document a stable "new
            // releases" source for this client) — its absence or failure
            // must not surface alongside real catalog failures, so it just
            // hides the section instead.
            failures.append(error.localizedDescription)
            newReleases = []
        }
        do {
            playlists = try await playlistsResult
        } catch is CancellationError {
            homeCatalogStore.cancelRefreshing(refreshID: refreshID)
            return
        } catch {
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
            let result = try await self.webAuthService.exchange(
                cookieHeader: cookie,
                webUserAgent: webUserAgent
            )
            try Task.checkCancellation()

            // Never let an exchange started for an old account overwrite a
            // logout, a new login or a token rotated by another workflow.
            guard let currentSession = self.sessionStore.session else {
                throw CancellationError()
            }
            guard self.sessionStore.sessionRevision == baselineRevision,
                  currentSession == baselineSession else {
                await self.musicService.configure(
                    userAgent: currentSession.userAgent
                )
                self.onUserAgentChanged(currentSession.userAgent)
                return currentSession.accessToken
            }

            await self.musicService.configure(userAgent: result.apiUserAgent)
            self.onUserAgentChanged(result.apiUserAgent)
            do {
                let profile = try await self.musicService.profile(
                    accessToken: result.accessToken
                )
                try Task.checkCancellation()

                guard let latestSession = self.sessionStore.session else {
                    throw CancellationError()
                }
                guard self.sessionStore.sessionRevision == baselineRevision,
                      latestSession == baselineSession else {
                    await self.musicService.configure(
                        userAgent: latestSession.userAgent
                    )
                    self.onUserAgentChanged(latestSession.userAgent)
                    return latestSession.accessToken
                }

                try self.sessionStore.updateWebSession(
                    result,
                    profile: profile
                )
                return result.accessToken
            } catch {
                let retainedUserAgent = self.sessionStore.session?.userAgent
                await self.musicService.configure(
                    userAgent: retainedUserAgent
                )
                self.onUserAgentChanged(retainedUserAgent)
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
