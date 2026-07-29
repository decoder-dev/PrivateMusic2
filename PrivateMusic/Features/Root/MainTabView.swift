import SwiftUI

struct MainTabView: View {
    private enum Tab: Hashable {
        case home
        case library
        case search
        case profile
    }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CatalogView()
                    .safeAreaInset(edge: .bottom, spacing: 6) {
                        miniPlayerInset
                    }
            }
            .tag(Tab.home)
            .tabItem {
                Label("Главная", systemImage: "house.fill")
            }

            NavigationStack {
                LibraryView()
                    .safeAreaInset(edge: .bottom, spacing: 6) {
                        miniPlayerInset
                    }
            }
            .tag(Tab.library)
            .tabItem {
                Label("Медиатека", systemImage: "music.note.list")
            }

            NavigationStack {
                SearchView()
                    .safeAreaInset(edge: .bottom, spacing: 6) {
                        miniPlayerInset
                    }
            }
            .tag(Tab.search)
            .tabItem {
                Label("Поиск", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ProfileView()
                    .safeAreaInset(edge: .bottom, spacing: 6) {
                        miniPlayerInset
                    }
            }
            .tag(Tab.profile)
            .tabItem {
                Label("Профиль", systemImage: "person.crop.circle")
            }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(
            settings.theme.colors[0],
            for: .tabBar
        )
        .tint(settings.theme.accent)
    }

    @ViewBuilder
    private var miniPlayerInset: some View {
        if player.currentTrack != nil {
            MiniPlayerView()
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }
}
