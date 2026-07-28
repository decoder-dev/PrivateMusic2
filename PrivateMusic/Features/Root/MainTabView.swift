import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Моя музыка", systemImage: "music.note.list")
            }

            NavigationStack {
                CatalogView()
            }
            .tabItem {
                Label("Главная", systemImage: "sparkles")
            }

            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("Поиск", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Профиль", systemImage: "person.crop.circle")
            }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(
            settings.theme.colors[0].opacity(0.82),
            for: .tabBar
        )
    }
}
