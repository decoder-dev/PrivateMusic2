import SwiftUI

/// Mix is not a root destination. Home holds now-playing plus one next
/// step; the full hub (VK catalog, Selena controls, moods) is Explore,
/// pushed from Home. Four root tabs read as one product.
private enum MainTab: CaseIterable, Hashable, Identifiable {
    case home
    case library
    case search
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        case .home: L10n.text("tab.home")
        case .library: L10n.text("tab.library")
        case .search: L10n.text("tab.search")
        case .profile: L10n.text("tab.profile")
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
    @Environment(AppSettings.self) private var settings
    @Environment(AudioPlayer.self) private var player
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
            } else if #available(iOS 26.0, *), !settings.classicChrome {
                SystemLiquidGlassTabView(
                    selection: $selectedTab,
                    playerNamespace: playerNamespace
                )
            } else {
                // Also the iOS 26 path when the classic look is pinned: the
                // system tab bar and its floating `tabViewBottomAccessory`
                // mini player are where most of the Liquid Glass a user sees
                // actually comes from, so leaving them in place made the
                // switch look like it did nothing.
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
        [.home, .library, .search, .profile]
    }

    /// Custom floating dock for iOS 16–25. iOS 26.0+ uses the system
    /// `TabView` + `tabViewBottomAccessory` path above.
    private var legacyTabStack: some View {
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
                // Reservation goes through BottomAccessoryMetrics so the
                // dock, the mini player and the clearance between them are
                // decided in one place. Before the dock has measured
                // itself the estimate still clears it, which is what used
                // to let the first shelf paint underneath on the first
                // frame.
                Color.clear
                    .frame(
                        height: BottomAccessoryMetrics.inset(
                            measuredDockHeight: dockHeight,
                            hasMiniPlayer: player.currentTrack != nil
                        )
                    )
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
                showsOwnGlassChrome: false,
                fillsAccessorySlot: true
            )
            .padding(.horizontal, 4)
            .frame(maxHeight: MiniPlayerLayoutMetrics.accessoryMaxHeight)
            .clipped()
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
        // Spacing/padding here directly sets how far the floating dock sits
        // above the home indicator, because the overlay is already aligned
        // to the safe area. Keep it tight: the dock reads as detached and
        // wastes usable screen when it floats high.
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
        .padding(.top, 6)
        .padding(.bottom, 0)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: player.currentTrack?.id
        )
    }

    private var primaryTabs: [MainTab] {
        [.home, .library, .profile]
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
            VStack(spacing: BubbleSpacing.xs - 1) {
                Image(systemName: tab.image)
                    .font(.system(size: 19, weight: .semibold))
                    // Deliberately small: the selection surface carries the
                    // state, so the row never reflows as tabs change.
                    .scaleEffect(selection == tab ? 1.02 : 1)
                    .frame(width: 34, height: 26)
                    .background {
                        if selection == tab {
                            // Chrome is a capsule, per BubbleShapeLanguage.
                            BubbleShapeLanguage.chrome
                                .fill(settings.theme.accent.opacity(0.18))
                        }
                    }
                Text(tab.title)
                    .font(BubbleType.micro)
                    // Weight, not size, carries selection. `.micro` is
                    // already medium; regular here made the inactive row
                    // read a step lighter than the rest of the chrome.
                    .fontWeight(selection == tab ? .semibold : .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .animation(
                BubbleMotion.state(reduceMotion: reduceMotion),
                value: selection
            )
            .foregroundStyle(
                selection == tab
                    ? selectedColor
                    : Color.primary.opacity(0.72)
            )
            .frame(maxWidth: .infinity)
            .frame(height: BubbleMetrics.minimumTapTarget + 4)
            .contentShape(Capsule())
        }
        .buttonStyle(BubblePressStyle())
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
