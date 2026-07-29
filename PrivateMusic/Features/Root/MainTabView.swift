import SwiftUI

private enum MainTab: CaseIterable, Hashable {
    case home
    case library
    case search
    case profile

    var title: String {
        switch self {
        case .home: "Главная"
        case .library: "Медиатека"
        case .search: "Поиск"
        case .profile: "Профиль"
        }
    }

    var image: String {
        switch self {
        case .home: "house.fill"
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        case .profile: "person.crop.circle"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @State private var selectedTab: MainTab = .home

    var body: some View {
        ZStack {
            tabScreen(.home) {
                NavigationStack { CatalogView() }
            }
            tabScreen(.library) {
                NavigationStack { LibraryView() }
            }
            tabScreen(.search) {
                NavigationStack { SearchView() }
            }
            tabScreen(.profile) {
                NavigationStack { ProfileView() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlaybackTabDock(selection: $selectedTab)
        }
        .task(id: sessionStore.accessToken) {
            await refreshLibraryIndex()
        }
    }

    private func tabScreen<Content: View>(
        _ tab: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }

    private func refreshLibraryIndex() async {
        guard let token = sessionStore.accessToken else { return }
        var collected: [Track] = []
        var offset = 0
        var pageCount = 0
        do {
            while pageCount < 10 {
                let page = try await environment.musicService.library(
                    accessToken: token,
                    offset: offset,
                    count: 100
                )
                collected.append(contentsOf: page.items)
                pageCount += 1
                guard let next = page.nextOffset else { break }
                offset = next
            }
            guard !Task.isCancelled else { return }
            libraryStore.replace(with: collected)
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}

private struct PlaybackTabDock: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Binding var selection: MainTab

    var body: some View {
        VStack(spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 7)
                Divider().opacity(0.5)
            }

            HStack(spacing: 0) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Button {
                        Haptics.selection()
                        selection = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.image)
                                .font(.system(size: 20, weight: .semibold))
                            Text(tab.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(
                            selection == tab
                                ? settings.theme.accent
                                : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        selection == tab ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .background(
            settings.theme.colors[0]
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Divider().opacity(0.7)
        }
    }
}
