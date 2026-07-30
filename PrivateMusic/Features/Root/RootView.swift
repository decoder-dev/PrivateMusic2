import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshError: String?
    @State private var automaticRetryTask: Task<Void, Never>?
    @State private var automaticRetryAttempt = 0
    @State private var isValidatingSession = false
    @State private var refreshRequiresReplacement = false

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
                environment.cancelSessionRecovery()
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
        } else if environment.isRecoveringSession {
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
                }
            )
        }
    }

    private func maintainSession() async {
        guard let session = sessionStore.session else { return }
        await environment.musicService.configure(userAgent: session.userAgent)
        environment.player.configureNetwork(userAgent: session.userAgent)

        if session.shouldRefreshProactively {
            await refreshWebSession()
        } else {
            await loadProfile(forceValidation: true)
        }

        guard let current = sessionStore.session,
              current.canRefresh else {
            return
        }
        let delay = current.expiresAt.map {
            max($0.timeIntervalSinceNow - 90, 1)
        } ?? 900
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, scenePhase == .active else { return }
        if current.shouldRefreshProactively {
            await refreshWebSession()
        } else {
            await loadProfile(forceValidation: true)
        }
    }

    private func recoverActiveSession() async {
        guard let session = sessionStore.session else { return }
        if session.shouldRefreshProactively {
            await refreshWebSession()
        } else {
            await loadProfile(forceValidation: true)
        }
    }

    @MainActor
    private func refreshWebSession(
        tokenWasRejected: Bool = false
    ) async {
        guard networkMonitor.isReachable else {
            refreshError = nil
            return
        }
        guard let session = sessionStore.session,
              session.canRefresh else {
            refreshError =
                "Автовосстановление VK недоступно — откройте профиль"
            return
        }
        let mustReplaceToken =
            tokenWasRejected || refreshRequiresReplacement

        if mustReplaceToken {
            refreshError = "Восстанавливаем сессию VK…"
        } else {
            refreshError = nil
        }
        do {
            _ = try await environment.recoverSession()
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            automaticRetryAttempt = 0
            refreshRequiresReplacement = false
            refreshError = nil
        } catch is CancellationError {
            return
        } catch let error as APIError where error.isConnectivityFailure {
            refreshError = "VK пока не отвечает — сессия сохранена"
            scheduleAutomaticRetry()
        } catch let error as APIError where error == .unauthorized {
            refreshRequiresReplacement = mustReplaceToken
            refreshError = sessionStore.session?.canRefresh == true
                ? "Восстанавливаем подключение VK…"
                : "Автовосстановление VK недоступно — откройте профиль"
            scheduleAutomaticRetry()
        } catch {
            refreshRequiresReplacement = mustReplaceToken
            refreshError = mustReplaceToken
                ? "Восстанавливаем подключение VK…"
                : "VK пока не отвечает — сессия сохранена"
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
                      let session = sessionStore.session,
                      refreshRequiresReplacement
                        || session.shouldRefreshProactively
                        || refreshError != nil else {
                    return
                }
                await refreshWebSession(
                    tokenWasRejected: refreshRequiresReplacement
                )
            } catch {
                return
            }
        }
    }

    private func loadProfile(forceValidation: Bool = false) async {
        guard forceValidation || sessionStore.profile == nil else {
            return
        }
        guard !isValidatingSession,
              sessionStore.accessToken != nil else {
            return
        }
        isValidatingSession = true
        defer { isValidatingSession = false }
        do {
            let profile = try await environment.withAuthorizedToken { token in
                try await environment.musicService.profile(
                    accessToken: token
                )
            }
            sessionStore.setProfile(profile)
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            automaticRetryAttempt = 0
            refreshRequiresReplacement = false
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            if let apiError = error as? APIError,
               apiError == .unauthorized {
                if sessionStore.session?.canRefresh == true {
                    refreshRequiresReplacement = true
                    refreshError = "Восстанавливаем подключение VK…"
                    scheduleAutomaticRetry()
                } else {
                    refreshError =
                        "Автовосстановление VK недоступно — откройте профиль"
                }
            } else if let apiError = error as? APIError,
                      apiError.isConnectivityFailure {
                refreshError = "VK пока не отвечает — сессия сохранена"
            } else {
                refreshError = "VK пока не отвечает — сессия сохранена"
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
