import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Моя музыка", systemImage: "music.note.list")
            }

            NavigationStack {
                MixView()
            }
            .tabItem {
                Label("Микс", systemImage: "sparkles")
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
        .toolbarBackground(Brand.surface.opacity(0.96), for: .tabBar)
    }
}

