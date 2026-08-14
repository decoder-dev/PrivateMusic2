import SwiftUI

private enum MainTab: CaseIterable, Hashable, Identifiable {
    case home
    case mix
    case library
    case search
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        case .home: L10n.text("tab.home")
        case .mix: L10n.text("tab.mix")
        case .library: L10n.text("tab.library")
        case .search: L10n.text("tab.search")
        case .profile: L10n.text("tab.profile")
        }
    }

    var image: String {
        switch self {
        case .home: "house.fill"
        case .mix: "sparkles"
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        case .profile: "person.crop.circle"
        }
    }

    var scrollDestination: MainTabScrollDestination {
        switch self {
        case .home: .home
        case .mix: .mix
        case .library: .library
        case .search: .search
        case .profile: .profile
        }
    }
}

/// Measured height of the combined mini player + tab dock, used to
/// reserve exactly that much space above each tab's content on the
/// custom (pre–iOS 26) dock path.
private struct PlaybackDockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(
        value: inout CGFloat,
        nextValue: () -> CGFloat
    ) {
        value = max(value, nextValue())
    }
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: MainTab = .home
    @State private var scrollCoordinator = MainTabScrollCoordinator()
    @State private var dockHeight: CGFloat = 0
    let playerNamespace: Namespace.ID

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularWidthSplitView
            } else if #available(iOS 26.0, *) {
                SystemLiquidGlassTabView(
                    selection: $selectedTab,
                    playerNamespace: playerNamespace
                )
            } else {
                legacyTabStack
            }
        }
        .environment(scrollCoordinator)
        .task(id: sessionStore.accessToken) {
            async let library: Void = environment.refreshLibraryIndex()
            async let albums: Void = environment.refreshLikedAlbums()
            async let home: Void = environment.refreshHomeCatalog()
            _ = await (library, albums, home)
        }
    }

    /// iPad / regular-width sidebar. Used on iOS 26 as well — compact
    /// widths keep `SystemLiquidGlassTabView`.
    ///
    /// `List(selection:content:)` is macOS-only; iOS needs the collection
    /// initializer with an optional `Binding<SelectionValue?>`.
    private var regularWidthSplitView: some View {
        NavigationSplitView {
            List(sidebarTabs, selection: sidebarSelection) { tab in
                Label(tab.title, systemImage: tab.image)
                    .tag(tab)
                    .accessibilityAddTraits(
                        tab == selectedTab ? .isSelected : []
                    )
                    .accessibilityHint(
                        tab == selectedTab
                            ? ""
                            : L10n.text("tab.switch_hint")
                    )
            }
            .navigationTitle(L10n.text("private_music"))
            .listStyle(.sidebar)
        } detail: {
            regularTabDetail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    RegularWidthPlaybackBar(
                        playerNamespace: playerNamespace
                    )
                }
        }
    }

    private var sidebarSelection: Binding<MainTab?> {
        Binding(
            get: { selectedTab },
            set: { if let tab = $0 { selectedTab = tab } }
        )
    }

    @ViewBuilder
    private var regularTabDetail: some View {
        switch selectedTab {
        case .home:
            NavigationStack { CatalogView() }
        case .mix:
            NavigationStack { MixesHubView() }
        case .library:
            NavigationStack { LibraryView() }
        case .search:
            NavigationStack {
                SearchView(isActive: selectedTab == .search)
            }
        case .profile:
            NavigationStack { ProfileView() }
        }
    }

    private var sidebarTabs: [MainTab] {
        [.home, .mix, .library, .search, .profile]
    }

    /// Custom floating dock for iOS 16–25. iOS 26.0+ uses the system
    /// `TabView` + `tabViewBottomAccessory` path above.
    private var legacyTabStack: some View {
        ZStack {
            tabScreen(.home) {
                NavigationStack { CatalogView() }
            }
            tabScreen(.mix) {
                NavigationStack { MixesHubView() }
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
        .overlay(alignment: .bottom) {
            PlaybackTabDock(
                selection: $selectedTab,
                playerNamespace: playerNamespace
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PlaybackDockHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .onPreferenceChange(PlaybackDockHeightKey.self) { height in
            let rounded = height.rounded()
            // Ignore sub-point spring intermediates so tab safe-area insets
            // do not thrash every animation frame when the mini player appears.
            guard abs(rounded - dockHeight) >= 1 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dockHeight = rounded
            }
        }
    }

    /// The dock is an overlay rather than an outer `safeAreaInset` so that
    /// every tab's own `NavigationStack` gets the reservation directly:
    /// an inset applied outside a NavigationStack does not reliably reach
    /// the scrollable content inside it.
    private func tabScreen<Content: View>(
        _ tab: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: dockHeight)
                    .accessibilityHidden(true)
            }
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .zIndex(selectedTab == tab ? 1 : 0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: selectedTab
            )
    }
}

// MARK: - System Liquid Glass tabs (iOS 26.0+)

@available(iOS 26.0, *)
private struct SystemLiquidGlassTabView: View {
    @Environment(AudioPlayer.self) private var player
    @Binding var selection: MainTab
    let playerNamespace: Namespace.ID

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                MainTab.home.title,
                systemImage: MainTab.home.image,
                value: MainTab.home
            ) {
                NavigationStack { CatalogView() }
            }

            Tab(
                MainTab.mix.title,
                systemImage: MainTab.mix.image,
                value: MainTab.mix
            ) {
                NavigationStack { MixesHubView() }
            }

            Tab(
                MainTab.library.title,
                systemImage: MainTab.library.image,
                value: MainTab.library
            ) {
                NavigationStack { LibraryView() }
            }

            Tab(
                MainTab.profile.title,
                systemImage: MainTab.profile.image,
                value: MainTab.profile
            ) {
                NavigationStack { ProfileView() }
            }

            Tab(
                MainTab.search.title,
                systemImage: MainTab.search.image,
                value: MainTab.search
            ) {
                NavigationStack {
                    SearchView(isActive: selection == .search)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(
            PlaybackAccessoryModifier(
                isEnabled: player.currentTrack != nil,
                playerNamespace: playerNamespace
            )
        )
    }
}

/// `tabViewBottomAccessory(isEnabled:)` is iOS 26.1+; on 26.0 fall back to
/// the content-only overload and hide with `EmptyView`.
@available(iOS 26.0, *)
private struct PlaybackAccessoryModifier: ViewModifier {
    let isEnabled: Bool
    let playerNamespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                SystemPlaybackAccessory(playerNamespace: playerNamespace)
            }
        } else {
            content.tabViewBottomAccessory {
                if isEnabled {
                    SystemPlaybackAccessory(playerNamespace: playerNamespace)
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct SystemPlaybackAccessory: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    let playerNamespace: Namespace.ID

    var body: some View {
        switch MiniPlayerAccessoryPolicy.presentation(
            hasCurrentTrack: player.currentTrack != nil,
            mode: MiniPlayerAccessoryMode(placement: accessoryPlacement)
        ) {
        case .hidden:
            EmptyView()
        case .expanded:
            // System accessory already supplies Liquid Glass — don't stack
            // a second glass plate (looks like a floating black pill).
            MiniPlayerView(
                playerNamespace: playerNamespace,
                showsOwnGlassChrome: false
            )
            .padding(.horizontal, 4)
        case .inline:
            // Compact chrome sized for the minimized system tab bar.
            InlineMiniPlayerView(playerNamespace: playerNamespace)
        }
    }
}

@available(iOS 26.0, *)
private extension MiniPlayerAccessoryMode {
    init(placement: TabViewBottomAccessoryPlacement?) {
        switch placement {
        case .expanded:
            self = .expanded
        case .inline:
            self = .inline
        case .none:
            // Placement unresolved (first layout pass) — prefer full chrome.
            self = .expanded
        @unknown default:
            // Prefer compact chrome for unknown future placements so content
            // cannot clip against a minimized system tab bar.
            self = .inline
        }
    }
}

// MARK: - Regular-width mini player (iPad / Plus landscape)

private struct RegularWidthPlaybackBar: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playerNamespace: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView(playerNamespace: playerNamespace)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 5)
                    .transition(
                        .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: player.currentTrack?.id
        )
    }
}

// MARK: - Legacy custom dock (iOS 16–25)

private struct PlaybackTabDock: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: MainTab
    let playerNamespace: Namespace.ID

    var body: some View {
        // Do NOT wrap mini-player + tab capsule + search in one
        // GlassEffectContainer: iOS 26 morphs sibling glass into floating
        // orbs (giant search circle, detached mini-player pill, stray
        // accent blobs). Glass stays on each chrome piece individually.
        VStack(spacing: 12) {
            if player.currentTrack != nil {
                MiniPlayerView(playerNamespace: playerNamespace)
                    .transition(
                        .move(edge: .bottom).combined(with: .opacity)
                    )
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(primaryTabs, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .padding(5)
                .adaptiveGlass(
                    in: Capsule(style: .continuous),
                    interactive: true,
                    tint: settings.theme.accent.opacity(0.06)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)

                searchTabButton
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

    private var primaryTabs: [MainTab] {
        [.home, .mix, .library, .profile]
    }

    private var searchTabButton: some View {
        Button {
            selectTab(.search)
        } label: {
            Image(systemName: MainTab.search.image)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    selection == .search
                        ? selectedColor
                        : Color.primary.opacity(0.72)
                )
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(
            in: Circle(),
            interactive: true,
            tint: selection == .search
                ? settings.theme.accent.opacity(0.16)
                : settings.theme.accent.opacity(0.06)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityLabel(MainTab.search.title)
        .accessibilityAddTraits(selection == .search ? .isSelected : [])
    }

    private func tabButton(_ tab: MainTab) -> some View {
        Button {
            selectTab(tab)
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
                    .minimumScaleFactor(0.78)
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
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private func selectTab(_ tab: MainTab) {
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
    }

    private var selectedColor: Color {
        settings.theme.accent
    }
}
