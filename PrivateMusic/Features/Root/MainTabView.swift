import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case home
        case library
        case search
        case player
        case profile
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CatalogView()
            }
            .tag(Tab.home)
            .tabItem {
                Label("Главная", systemImage: "house.fill")
            }

            NavigationStack {
                LibraryView()
            }
            .tag(Tab.library)
            .tabItem {
                Label("Медиатека", systemImage: "music.note.list")
            }

            NavigationStack {
                SearchView()
            }
            .tag(Tab.search)
            .tabItem {
                Label("Поиск", systemImage: "magnifyingglass")
            }

            PlayerView(showsCloseButton: false)
                .tag(Tab.player)
                .tabItem {
                    Label("Плеер", systemImage: "play.circle.fill")
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
            if player.currentTrack != nil, selectedTab != .player {
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
    }
}
