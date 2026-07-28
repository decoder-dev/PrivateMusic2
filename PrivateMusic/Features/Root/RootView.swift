import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Group {
            if sessionStore.session == nil {
                ConnectView()
            } else {
                MainTabView()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if player.currentTrack != nil {
                            MiniPlayerView()
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                        }
                    }
                    .sheet(isPresented: $player.isPlayerPresented) {
                        PlayerView()
                    }
                    .task {
                        await loadProfile()
                    }
            }
        }
        .tint(Brand.accent)
        .background(Brand.background.ignoresSafeArea())
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
            sessionStore.errorMessage = error.localizedDescription
        }
    }
}

