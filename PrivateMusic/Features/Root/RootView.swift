import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @State private var isRefreshingSession = false
    @State private var refreshError: String?

    var body: some View {
        Group {
            if sessionStore.session == nil {
                ConnectView()
            } else if sessionStore.session?.needsRefresh == true {
                sessionRecoveryView
            } else {
                MainTabView()
                    .fullScreenCover(isPresented: $player.isPlayerPresented) {
                        PlayerView()
                    }
            }
        }
        .task(id: sessionStore.session?.accessToken) {
            await maintainSession()
        }
        .onChange(of: sessionStore.session == nil) { isLoggedOut in
            if isLoggedOut {
                player.stop()
            }
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

    private var sessionRecoveryView: some View {
        VStack(spacing: 18) {
            if isRefreshingSession || refreshError == nil {
                ProgressView()
                    .controlSize(.large)
                Text("Обновляем сессию VK…")
                    .font(.headline)
                Text("Повторный ввод номера обычно не требуется.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Не удалось обновить сессию")
                    .font(.title3.bold())
                Text(refreshError ?? "Проверьте подключение к интернету.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("Повторить") {
                    Task { await refreshWebSession() }
                }
                .buttonStyle(.borderedProminent)
                Button("Войти заново", role: .destructive) {
                    sessionStore.logout()
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
    }

    private func maintainSession() async {
        guard let session = sessionStore.session else { return }
        if session.needsRefresh {
            await refreshWebSession()
            return
        }
        await loadProfile()

        guard let expiresAt = session.expiresAt,
              session.canRefresh else {
            return
        }
        let delay = max(
            expiresAt.timeIntervalSinceNow - 90,
            1
        )
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        await refreshWebSession()
    }

    @MainActor
    private func refreshWebSession() async {
        guard let session = sessionStore.session,
              let cookie = session.refreshCookie,
              let webUserAgent = session.webUserAgent else {
            refreshError = "Эта сессия создана старой версией приложения. "
                + "Войдите заново один раз — следующие обновления будут "
                + "проходить автоматически."
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
        } catch is CancellationError {
            return
        } catch {
            refreshError = error.localizedDescription
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
        } catch is CancellationError {
            return
        } catch {
            if let apiError = error as? APIError,
               apiError == .unauthorized {
                if sessionStore.session?.canRefresh == true {
                    await refreshWebSession()
                } else {
                    sessionStore.logout()
                }
            } else {
                sessionStore.errorMessage = error.localizedDescription
            }
        }
    }
}
