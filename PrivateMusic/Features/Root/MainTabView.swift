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
}

struct MainTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
}

private struct PlaybackTabDock: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: MainTab

    var body: some View {
        AdaptiveGlassContainer(spacing: 10) {
            VStack(spacing: 8) {
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
                    interactive: true
                )
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
                Text(tab.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                selection == tab
                    ? selectedColor
                    : Color.primary.opacity(0.58)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if selection == tab {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var selectedColor: Color {
        settings.theme == .light ? .black : .white
    }
}
