import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if sessionStore.session == nil {
                ConnectView()
            } else {
                MainTabView()
                    .sheet(isPresented: $player.isPlayerPresented) {
                        PlayerView()
                    }
                    .task {
                        await loadProfile()
                    }
            }
        }
        .tint(settings.theme.accent)
        .background(ThemeBackground())
        .preferredColorScheme(settings.appearance.colorScheme)
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
        } catch {
            if let apiError = error as? APIError,
               apiError == .unauthorized {
                sessionStore.logout()
            } else {
                sessionStore.errorMessage = error.localizedDescription
            }
        }
    }
}
