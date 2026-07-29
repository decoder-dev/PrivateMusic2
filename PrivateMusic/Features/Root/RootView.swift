import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRefreshingSession = false
    @State private var refreshError: String?
    @State private var automaticRetryTask: Task<Void, Never>?
    @State private var automaticRetryAttempt = 0

    var body: some View {
        Group {
            if sessionStore.session == nil {
                ConnectView()
            } else {
                MainTabView()
                    .fullScreenCover(isPresented: $player.isPlayerPresented) {
                        PlayerView()
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        connectionBanner
                    }
            }
        }
        .task(id: sessionStore.session?.accessToken) {
            await maintainSession()
        }
        .onChange(of: sessionStore.session == nil) { isLoggedOut in
            if isLoggedOut {
                automaticRetryTask?.cancel()
                automaticRetryTask = nil
                automaticRetryAttempt = 0
                player.stop()
                refreshError = nil
            }
        }
        .onChange(of: networkMonitor.revision) { _ in
            guard networkMonitor.isReachable,
                  sessionStore.session != nil,
                  sessionStore.session?.needsRefresh == true
                    || refreshError != nil else {
                return
            }
            Task { await refreshWebSession() }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, sessionStore.session != nil else {
                return
            }
            Task { await recoverActiveSession() }
        }
        .tint(settings.theme.accent)
        .background(ThemeBackground())
        .preferredColorScheme(settings.theme.colorScheme)
        .appTextScale(settings.textScale)
        .alert(
            "Ошибка воспроизведения",
            isPresented: Binding(
                get: { player.errorMessage != nil },
                set: { if !$0 { player.errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
        .alert(
            "Ошибка сессии",
            isPresented: Binding(
                get: { sessionStore.errorMessage != nil },
                set: { if !$0 { sessionStore.errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(sessionStore.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if networkMonitor.state == .offline {
            ConnectionBanner(
                icon: "wifi.slash",
                message: "Нет сети — сессия сохранена",
                tint: .orange
            )
        } else if isRefreshingSession {
            ConnectionBanner(
                icon: nil,
                message: "Обновляем подключение VK…",
                tint: settings.theme.accent,
                showsProgress: true
            )
        } else if let refreshError {
            ConnectionBanner(
                icon: "exclamationmark.circle.fill",
                message: refreshError,
                tint: .orange,
                retry: {
                    Task { await refreshWebSession() }
                },
                loginAgain: {
                    sessionStore.logout()
                }
            )
        }
    }

    private func maintainSession() async {
        guard let session = sessionStore.session else { return }
        await environment.musicService.configure(userAgent: session.userAgent)
        environment.player.configureNetwork(userAgent: session.userAgent)

        if session.needsRefresh
            || (session.expiresAt == nil && session.canRefresh) {
            await refreshWebSession()
        } else {
            await loadProfile()
        }

        guard let current = sessionStore.session,
              current.canRefresh else {
            return
        }
        let delay = current.expiresAt.map {
            max($0.timeIntervalSinceNow - 90, 1)
        } ?? 1_800
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, scenePhase == .active else { return }
        await refreshWebSession()
    }

    private func recoverActiveSession() async {
        guard let session = sessionStore.session else { return }
        if session.needsRefresh
            || (session.expiresAt == nil && session.canRefresh)
            || refreshError != nil {
            await refreshWebSession()
        } else {
            await loadProfile()
        }
    }

    @MainActor
    private func refreshWebSession() async {
        guard !isRefreshingSession else { return }
        guard networkMonitor.isReachable else {
            refreshError = nil
            return
        }
        guard let session = sessionStore.session,
              let cookie = session.refreshCookie,
              let webUserAgent = session.webUserAgent else {
            refreshError = "Нужно один раз войти заново"
            return
        }

        isRefreshingSession = true
        refreshError = nil
        defer { isRefreshingSession = false }
        do {
            let result = try await environment.webAuthService.exchange(
                cookieHeader: cookie,
                webUserAgent: webUserAgent
            )
            await environment.musicService.configure(
                userAgent: result.apiUserAgent
            )
            environment.player.configureNetwork(
                userAgent: result.apiUserAgent
            )
            let profile = try await environment.musicService.profile(
                accessToken: result.accessToken
            )
            try sessionStore.updateWebSession(result, profile: profile)
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            automaticRetryAttempt = 0
            refreshError = nil
        } catch is CancellationError {
            return
        } catch let error as APIError where error.isConnectivityFailure {
            refreshError = "VK временно недоступен"
            scheduleAutomaticRetry()
        } catch let error as APIError where error == .unauthorized {
            refreshError = "Сессия VK истекла"
        } catch {
            refreshError = "Не удалось обновить подключение"
            scheduleAutomaticRetry()
        }
    }

    @MainActor
    private func scheduleAutomaticRetry() {
        guard sessionStore.session?.canRefresh == true else { return }
        automaticRetryTask?.cancel()
        automaticRetryAttempt += 1
        let delay = min(
            pow(2, Double(automaticRetryAttempt - 1)) * 8,
            60
        )
        automaticRetryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard networkMonitor.isReachable,
                      sessionStore.session != nil,
                      refreshError != nil else {
                    return
                }
                await refreshWebSession()
            } catch {
                return
            }
        }
    }

    private func loadProfile() async {
        guard sessionStore.profile == nil,
              let token = sessionStore.accessToken else {
            return
        }
        do {
            let profile = try await environment.musicService.profile(
                accessToken: token
            )
            sessionStore.setProfile(profile)
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            if let apiError = error as? APIError,
               apiError == .unauthorized {
                if sessionStore.session?.canRefresh == true {
                    await refreshWebSession()
                } else {
                    refreshError = "Сессия VK истекла"
                }
            } else if let apiError = error as? APIError,
                      apiError.isConnectivityFailure {
                refreshError = "VK временно недоступен"
            } else {
                refreshError = "Не удалось проверить подключение"
            }
        }
    }
}

private struct ConnectionBanner: View {
    let icon: String?
    let message: String
    let tint: Color
    var showsProgress = false
    var retry: (() -> Void)?
    var loginAgain: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(tint)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            Text(message)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Повторить", action: retry)
                    .font(.footnote.weight(.bold))
            }
            if let loginAgain {
                Menu {
                    Button(
                        "Войти заново",
                        role: .destructive,
                        action: loginAgain
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
