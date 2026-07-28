import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case library
        case mix
        case search
        case profile
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @State private var selectedTab: Tab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .tag(Tab.library)
            .tabItem {
                Label("Моя музыка", systemImage: "music.note.list")
            }

            NavigationStack {
                MixView()
            }
            .tag(Tab.mix)
            .tabItem {
                Label("Микс", systemImage: "sparkles")
            }

            NavigationStack {
                SearchView()
            }
            .tag(Tab.search)
            .tabItem {
                Label("Поиск", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ProfileView()
            }
            .tag(Tab.profile)
            .tabItem {
                Label("Профиль", systemImage: "person.crop.circle")
            }
        }
        .overlay(alignment: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 54)
            }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(
            settings.theme.colors[0].opacity(0.82),
            for: .tabBar
        )
        .tint(settings.theme.accent)
    }
}
