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
    @State private var refreshNeedsLogin = false

    var body: some View {
        Group {
            if sessionStore.session == nil {
                ConnectView()
            } else {
                MainTabView()
                    .fullScreenCover(isPresented: $player.isPlayerPresented) {
                        PlayerView()
                            .playerPresentationBackground()
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        connectionBanner
                    }
            }
        }
        .task(id: sessionStore.sessionRevision) {
            environment.configureOfflineAccount()
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
                refreshNeedsLogin = false
            }
        }
        .onChange(of: networkMonitor.revision) { _ in
            guard networkMonitor.isReachable,
                  !refreshNeedsLogin,
                  let session = sessionStore.session,
                  session.needsRefresh || refreshError != nil else {
                return
            }
            Task {
                if session.needsRefresh {
                    await refreshWebSession()
                } else {
                    await loadProfile(forceValidation: true)
                }
            }
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
                retry: refreshNeedsLogin
                    ? nil
                    : { Task { await refreshWebSession() } }
            )
        }
    }

    private func maintainSession() async {
        guard let initialSession = sessionStore.session else { return }
        await environment.musicService.configure(
            userAgent: initialSession.userAgent
        )
        environment.player.configureNetwork(
            userAgent: initialSession.userAgent
        )

        while !Task.isCancelled, sessionStore.session != nil {
            if scenePhase == .active, !refreshNeedsLogin,
               let current = sessionStore.session {
                if current.shouldRefreshProactively {
                    await refreshWebSession()
                } else {
                    await loadProfile(forceValidation: true)
                }
            }

            guard let current = sessionStore.session else { return }
            let delay = current.maintenanceDelay()
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    private func recoverActiveSession() async {
        guard !refreshNeedsLogin,
              let session = sessionStore.session else { return }
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
            refreshNeedsLogin = true
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
            refreshNeedsLogin = false
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            switch SessionRecoveryDisposition.classify(error) {
            case .ignore:
                return
            case .retry:
                refreshRequiresReplacement = mustReplaceToken
                refreshError = "VK пока не отвечает — сессия сохранена"
                scheduleAutomaticRetry(usingWebSession: true)
            case .requiresLogin:
                automaticRetryTask?.cancel()
                automaticRetryTask = nil
                refreshRequiresReplacement = true
                refreshNeedsLogin = true
                refreshError =
                    "VK отклонил сохранённый вход — подключите аккаунт снова"
            }
        }
    }

    @MainActor
    private func scheduleAutomaticRetry(usingWebSession: Bool) {
        guard let currentSession = sessionStore.session else { return }
        guard !usingWebSession || currentSession.canRefresh else { return }
        guard !refreshNeedsLogin else { return }
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
                if usingWebSession
                    || refreshRequiresReplacement
                    || session.shouldRefreshProactively {
                    await refreshWebSession(
                        tokenWasRejected: refreshRequiresReplacement
                    )
                } else {
                    await loadProfile(forceValidation: true)
                }
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
            let validated = try await environment.withAuthorizedToken { token in
                let profile = try await environment.musicService.profile(
                    accessToken: token
                )
                return (profile: profile, accessToken: token)
            }
            guard sessionStore.setProfile(
                validated.profile,
                matchingAccessToken: validated.accessToken
            ) else {
                return
            }
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            automaticRetryAttempt = 0
            refreshRequiresReplacement = false
            refreshNeedsLogin = false
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            switch SessionRecoveryDisposition.classify(error) {
            case .ignore:
                return
            case .retry:
                refreshError = "VK пока не отвечает — сессия сохранена"
                scheduleAutomaticRetry(usingWebSession: false)
            case .requiresLogin:
                automaticRetryTask?.cancel()
                automaticRetryTask = nil
                refreshRequiresReplacement = true
                refreshNeedsLogin = true
                refreshError =
                    "VK отклонил сохранённый вход — подключите аккаунт снова"
            }
        }
    }
}

private struct ConnectionBanner: View {
    @EnvironmentObject private var settings: AppSettings
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
            Text(L10n.text(message))
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Повторить", action: retry)
                    .font(.footnote.weight(.bold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveGlass(in: bannerShape)
        .shadow(
            color: .black.opacity(settings.theme == .dark ? 0.16 : 0.08),
            radius: 8,
            y: 3
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PremiumLayout.compactRadius,
            style: .continuous
        )
    }
}

private extension View {
    @ViewBuilder
    func playerPresentationBackground() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.clear)
        } else {
            self
        }
    }
}
