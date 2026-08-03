import SwiftUI

private enum MainTab: CaseIterable, Hashable {
    case home
    case library
    case search
    case profile

    var title: String {
        switch self {
        case .home: L10n.text("Главная")
        case .library: L10n.text("Медиатека")
        case .search: L10n.text("Поиск")
        case .profile: L10n.text("Профиль")
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

    var scrollDestination: MainTabScrollDestination {
        switch self {
        case .home: .home
        case .library: .library
        case .search: .search
        case .profile: .profile
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @EnvironmentObject private var likedAlbumsStore: LikedAlbumsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: MainTab = .home
    @StateObject private var scrollCoordinator = MainTabScrollCoordinator()

    var body: some View {
        ZStack {
            tabScreen(.home) {
                NavigationStack { CatalogView() }
            }
            tabScreen(.library) {
                NavigationStack { LibraryView() }
            }
            tabScreen(.search) {
                NavigationStack {
                    SearchView(isActive: selectedTab == .search)
                }
            }
            tabScreen(.profile) {
                NavigationStack { ProfileView() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlaybackTabDock(selection: $selectedTab)
        }
        .environmentObject(scrollCoordinator)
        .task(id: sessionStore.accessToken) {
            async let library: Void = refreshLibraryIndex()
            async let albums: Void = refreshLikedAlbums()
            async let home: Void = environment.refreshHomeCatalog()
            _ = await (library, albums, home)
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
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: selectedTab
            )
    }

    private func refreshLibraryIndex() async {
        guard sessionStore.accessToken != nil else { return }
        var collected: [Track] = []
        var offset = 0
        var pageCount = 0
        do {
            while pageCount < 10 {
                let page = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.library(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
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

    private func refreshLikedAlbums() async {
        likedAlbumsStore.prepare(
            accountID: sessionStore.resolvedOfflineAccountID
        )
        guard sessionStore.accessToken != nil else { return }
        let refreshID = likedAlbumsStore.beginRefresh()
        var collected: [Album] = []
        var offset = 0
        do {
            for _ in 0..<10 {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.likedAlbums(
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
                collected.append(contentsOf: page.items)
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
            }
            guard !Task.isCancelled else { return }
            likedAlbumsStore.replace(with: collected, refreshID: refreshID)
        } catch {
            return
        }
    }
}

private struct PlaybackTabDock: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: MainTab

    var body: some View {
        AdaptiveGlassContainer(spacing: 4) {
            VStack(spacing: 12) {
                if player.currentTrack != nil {
                    MiniPlayerView()
                        .transition(
                            .move(edge: .bottom).combined(with: .opacity)
                        )
                }

                HStack(spacing: 4) {
                    ForEach(MainTab.allCases, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .padding(5)
                .adaptiveGlass(
                    in: RoundedRectangle(
                        cornerRadius: 24,
                        style: .continuous
                    ),
                    interactive: true,
                    tint: settings.theme.accent.opacity(0.06)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: player.currentTrack?.id
        )
    }

    private func tabButton(_ tab: MainTab) -> some View {
        Button {
            Haptics.selection()
            if TabReselectionPolicy.isReselection(
                current: selection,
                tapped: tab
            ) {
                scrollCoordinator.scrollToTop(tab.scrollDestination)
                return
            }
            if reduceMotion {
                selection = tab
            } else {
                withAnimation(
                    .spring(response: 0.32, dampingFraction: 0.82)
                ) {
                    selection = tab
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.image)
                    .font(.system(size: 20, weight: .semibold))
                    .scaleEffect(selection == tab ? 1.04 : 0.94)
                    .frame(width: 30, height: 26)
                    .background {
                        if selection == tab {
                            Circle()
                                .fill(settings.theme.accent.opacity(0.16))
                        }
                    }
                Text(tab.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                selection == tab
                    ? selectedColor
                    : Color.primary.opacity(0.72)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var selectedColor: Color {
        settings.theme.accent
    }
}
