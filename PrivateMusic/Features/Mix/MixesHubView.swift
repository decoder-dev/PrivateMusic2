import SwiftUI

/// Discovery destination pushed from Home. Selena and VK share the same
/// listening window. VK mix switching happens inline — no browse/detail
/// push. This is not a root tab.
struct MixesHubView: View {
    private enum HubTab: String, CaseIterable, Identifiable {
        case selena
        case vk

        var id: String { rawValue }

        var title: String {
            switch self {
            case .selena: L10n.text("selena.name")
            case .vk: L10n.text("vk_mixes_2")
            }
        }
    }

    /// «Продолжить поток» can render as a scannable list or a denser grid —
    /// user preference for how much of the expanded queue fits on screen.
    private enum TrackListLayout {
        case list
        case grid
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayer.self) private var player
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(HomeCatalogStore.self) private var homeCatalog
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(PinnedMixStore.self) private var pinnedMixStore
    @Environment(MixFeedbackStore.self) private var mixFeedbackStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hubTab: HubTab = .selena
    @State private var mixes: [MusicMix] = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var loadingMixID: String?
    @State private var actionError: String?
    @State private var trackLoadTask: Task<Void, Never>?
    /// Mix launches (play / mood / my-music) — never share a handle with
    /// list pagination, or a VK page load cancels the launch mid-flight.
    @State private var launchTask: Task<Void, Never>?
    @State private var seedRadioTask: Task<Void, Never>?

    @State private var selenaTracks: [Track] = []
    /// Unfiltered baseline for current Selena queue.
    /// Filters (language/familiarity/mood) may change without having to
    /// ask the server again.
    @State private var selenaTrackBase: [Track] = []
    @State private var selenaRationale: MixRationale = .empty
    @State private var selectedVKMix: MusicMix?
    @State private var vkTracks: [Track] = []
    @State private var vkRationale: MixRationale = .empty
    @State private var vkTrackCache: [String: [Track]] = [:]
    /// Unfiltered baseline for each VK mix.
    @State private var vkTrackBaseCache: [String: [Track]] = [:]
    @State private var vkRationaleCache: [String: MixRationale] = [:]
    @State private var sharingTrack: Track?
    @State private var selectedCurator: MixCurator?
    @State private var expandedTrackMixIDs: Set<String> = []
    @State private var trackListLayout: TrackListLayout = .list
    /// Viewport width from a background GeometryReader — wrapping the
    /// ScrollView itself re-laid the whole hub on every scroll frame
    /// (same sticky-scroll bug Home already fixed).
    @State private var containerWidth: CGFloat = 390
    /// Mix currently recommended on Home — keep it out of Explore's first
    /// visible VK slot so the two screens do not open on the same hero.
    var deprioritizedMixID: String? = nil
    /// Open this mix on the VK tab (from What's Next "Открыть микс").
    var focusedMixID: String? = nil
    /// When Home's What's Next is already the Selena station, open Explore
    /// on VK so the first screen is not the same hero again.
    var startsOnVK: Bool = false
    @State private var showingSelenaConfigure = false
    @State private var showingMixConfigure = false

    private let defaultPreviewTrackLimit = 15
    private let expandedPreviewTrackLimit = 60

    var body: some View {
        ScrollViewReader { proxy in
            let metrics = MixHubMetrics(width: containerWidth)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Color.clear
                        .frame(height: 0)
                        .id(MainTabScrollDestination.mix)

                    listenLaterBanner

                    switch hubTab {
                    case .selena:
                        selenaContent(metrics: metrics)
                    case .vk:
                        vkContent(metrics: metrics)
                    }

                    if let actionError {
                        actionErrorRow(actionError)
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, 8)
            }
            .clearsMiniPlayer(includingWhenDockReservesSpace: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MixHubWidthKey.self,
                        value: geometry.size.width
                    )
                }
            }
            .onPreferenceChange(MixHubWidthKey.self) { width in
                let rounded = width.rounded()
                if rounded > 0, abs(rounded - containerWidth) >= 1 {
                    containerWidth = rounded
                }
            }
            // Mode switch stays put — burying Selena/VK inside the scroll
            // made the screen's only primary navigation disappear after
            // one flick.
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker(L10n.text("tab.mix"), selection: $hubTab) {
                    ForEach(HubTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(L10n.text("mix_sections"))
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .onChange(of: scrollCoordinator.request) { _, request in
                guard request?.destination == .mix else { return }
                scrollHubToTop(proxy: proxy)
            }
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("explore_music"))
        .navigationBarTitleDisplayMode(.inline)
        .trackShareSheet(track: $sharingTrack)
        .navigationDestination(
            isPresented: Binding(
                get: { selectedCurator != nil },
                set: { if !$0 { selectedCurator = nil } }
            )
        ) {
            if let selectedCurator {
                CuratorMixesView(
                    curator: selectedCurator,
                    mixes: vkMixes.filter {
                        $0.curator?.id == selectedCurator.id
                    },
                    trackCache: vkTrackCache,
                    onPlay: { mix in
                        self.selectedCurator = nil
                        hubTab = .vk
                        start(mix)
                    }
                )
            }
        }
        .refreshable { await load(force: true) }
        .task(id: sessionStore.accessToken) { await load() }
        .sheet(isPresented: $showingSelenaConfigure) {
            MixConfigureSheet(scope: .selena) {
                startConfiguredSelena()
            }
        }
        .sheet(isPresented: $showingMixConfigure) {
            MixConfigureSheet(scope: .mix) {
                if let mix = selectedVKMix ?? orderedVKMixes.first {
                    start(mix)
                }
            }
        }
        .onAppear {
            if focusedMixID != nil || startsOnVK {
                hubTab = .vk
            }
        }
        .onChange(of: hubTab) { _, tab in
            if tab == .vk {
                ensureVKSelection()
            }
        }
        .onChange(of: environment.mixActionError) { _, error in
            guard let error else { return }
            actionError = error
            environment.mixActionError = nil
        }
        .onChange(of: settings.mixLanguagePreference) { _, _ in
            guard sessionStore.accessToken != nil else { return }
            if let current = currentMixForFilters() {
                refilterLoadedTracks(for: current)
            }
        }
        .onChange(of: settings.mixFamiliarityPreference) { _, _ in
            guard sessionStore.accessToken != nil else { return }
            if let current = currentMixForFilters() {
                refilterLoadedTracks(for: current)
            }
        }
        .onChange(of: settings.mixMoodPreference) { _, _ in
            guard sessionStore.accessToken != nil else { return }
            refilterLoadedTracks(for: personalMix)
        }
        .onChange(of: settings.selenaDiversityPreference) { _, _ in
            guard sessionStore.accessToken != nil else { return }
            refilterLoadedTracks(for: personalMix)
        }
        .onDisappear {
            trackLoadTask?.cancel()
            launchTask?.cancel()
            seedRadioTask?.cancel()
        }
    }

    // MARK: - Selena

    @ViewBuilder
    private func selenaContent(metrics: MixHubMetrics) -> some View {
        if isLoading && selenaTracks.isEmpty {
            skeleton(metrics: metrics)
        } else if let loadErrorMessage, selenaTracks.isEmpty {
            loadErrorState(loadErrorMessage)
        } else {
            listeningWindow(
                mix: personalMix,
                tracks: selenaTracks,
                rationale: selenaRationale,
                rationaleTitle: L10n.text("selena.why"),
                heroSubtitle: selenaHeroSubtitle,
                tracksSubtitle: L10n.text(
                    "selected_by_decoder_dev_s_neural_network_from_your_vk_listening"
                ),
                metrics: metrics,
                picker: {
                    selenaExtras(metrics: metrics)
                }
            )
        }
    }

    @ViewBuilder
    private func selenaExtras(metrics: MixHubMetrics) -> some View {
        selenaStationSummary(metrics: metrics)
            .premiumAppear(delay: 0.06)
        selenaQuickStarts
            .premiumAppear(delay: 0.08)
        // Selena owns the rich wave dial. Catalog vibe shelves live on the
        // VK tab so the personal station is not crowded with mix discovery.
        selenaWaveCard
            .premiumAppear(delay: 0.10)
        if !homeCatalog.newReleases.isEmpty {
            newReleasesLink
                .premiumAppear(delay: 0.14)
        }
    }

    /// Selena's wave tuner — moodEnergy / diversity / language (Yandex-like).
    private var selenaWaveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("selena.wave_card_title"))
                .font(.headline)
            Text(configuredSelenaSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                showingSelenaConfigure = true
            } label: {
                Label(
                    L10n.text("configure_selena"),
                    systemImage: "slider.horizontal.3"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.theme.accent)
            .disabled(loadingMixID != nil)
            .accessibilityHint(L10n.text("configure_selena_accessibility_hint"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var configuredSelenaSummary: String {
        var parts: [String] = []
        if settings.mixMoodPreference != .any {
            parts.append(settings.mixMoodPreference.title)
        }
        if settings.selenaDiversityPreference != .default {
            parts.append(settings.selenaDiversityPreference.chipTitle)
        }
        if settings.mixLanguagePreference != .any {
            parts.append(settings.mixLanguagePreference.title)
        }
        if parts.isEmpty {
            return L10n.text("selena.wave_card_empty")
        }
        return parts.joined(separator: " · ")
    }

    private var configuredMixSummary: String {
        var parts: [String] = []
        if settings.mixFamiliarityPreference != .any {
            parts.append(settings.mixFamiliarityPreference.chipTitle)
        }
        if settings.mixLanguagePreference != .any,
           settings.mixLanguagePreference != .instrumental {
            parts.append(settings.mixLanguagePreference.title)
        }
        if parts.isEmpty {
            return L10n.text("mix.basic_card_empty")
        }
        return parts.joined(separator: " · ")
    }

    /// Always stays on Selena — mood is a live wave dial, not a jump to a
    /// VK vibe shelf (Home chips still use MixMoodLaunchPolicy for that).
    private func startConfiguredSelena() {
        start(personalMix)
    }

    /// A quiet entry point, not another shelf: the album art already gets
    /// its own carousel inside `NewReleasesView`, so this only needs to
    /// say the section exists and hand off to it.
    private var newReleasesLink: some View {
        NavigationLink {
            NewReleasesView(albums: homeCatalog.newReleases)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("new_releases"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.text("fresh_albums"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .premiumCard(interactive: true)
    }

    // MARK: - VK

    @ViewBuilder
    private func vkContent(metrics: MixHubMetrics) -> some View {
        if isLoading && vkMixes.isEmpty {
            skeleton(metrics: metrics)
        } else if let loadErrorMessage, vkMixes.isEmpty {
            loadErrorState(loadErrorMessage)
        } else if vkMixes.isEmpty {
            emptyMixesState
        } else if let mix = selectedVKMix ?? orderedVKMixes.first {
            listeningWindow(
                mix: mix,
                tracks: vkTracks,
                rationale: vkRationale,
                rationaleTitle: L10n.text("why_this_mix"),
                heroSubtitle: cardSubtitle(for: mix),
                tracksSubtitle: vkTracksSubtitle(for: mix),
                metrics: metrics,
                picker: {
                    if orderedVKMixes.count > 1 {
                        vkMixPicker(selected: mix, metrics: metrics)
                    }
                    if !vibeShelves.isEmpty {
                        vibeShelfBlock(metrics: metrics)
                    }
                    vkMagazineShelves(metrics: metrics)
                }
            )
        }
    }

    // MARK: - Shared listening window

    @ViewBuilder
    private func listeningWindow<Picker: View>(
        mix: MusicMix,
        tracks: [Track],
        rationale: MixRationale,
        rationaleTitle: String,
        heroSubtitle: String,
        tracksSubtitle: String,
        metrics: MixHubMetrics,
        @ViewBuilder picker: () -> Picker
    ) -> some View {
        // First-page load: only the spinner — never paint hero/controls
        // underneath an overlay (feedback: indicator must replace UI).
        if loadingMixID == mix.id && tracks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 72)
                .accessibilityLabel(L10n.text("loading_recommendations_and_mixes"))
        } else {
            playHero(
                mix: mix,
                tracks: tracks,
                metrics: metrics,
                subtitle: heroSubtitle
            )
            .premiumAppear(delay: 0.02)

            mixMetadataStrip(mix: mix, tracks: tracks)
                .premiumAppear(delay: 0.04)

            if !rationale.isEmpty {
                rationaleBlock(rationale, title: rationaleTitle)
                    .premiumAppear(delay: 0.08)
            }

            controlsPanel(mix: mix, tracks: tracks)
                .premiumAppear(delay: 0.12)

            mixUtilityLinks(mix: mix, tracks: tracks)
                .premiumAppear(delay: 0.13)

            picker()

            if !tracks.isEmpty {
                tracksBlock(
                    mix: mix,
                    tracks: tracks,
                    subtitle: tracksSubtitle,
                    metrics: metrics
                )
                .premiumAppear(delay: 0.16)
            }
        }
    }

    @ViewBuilder
    private func vkMixPicker(
        selected: MusicMix,
        metrics: MixHubMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PremiumSectionHeader(
                "your_vk_mixes",
                subtitle: "same_screen_just_switch_the_mix"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(orderedVKMixes) { mix in
                        mixPickerCard(
                            mix,
                            isSelected: mix.id == selected.id,
                            metrics: metrics
                        )
                    }
                }
            }
        }
        .padding(.top, 4)
        .premiumAppear(delay: 0.12)
    }

    private func mixPickerCard(
        _ mix: MusicMix,
        isSelected: Bool,
        metrics: MixHubMetrics
    ) -> some View {
        let artTracks = vkTrackCache[mix.id] ?? homeCatalog.recommendations
        let cachedTracks = vkTrackCache[mix.id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    selectVKMix(mix)
                } label: {
                    ZStack(alignment: .topLeading) {
                        MixArtworkView(
                            mix: mix,
                            tracks: artTracks,
                            size: metrics.cardWidth,
                            height: metrics.cardHeight,
                            cornerRadius: PremiumLayout.compactRadius
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: PremiumLayout.compactRadius,
                                style: .continuous
                            )
                            .strokeBorder(
                                isSelected
                                    ? settings.theme.accent
                                    : .clear,
                                lineWidth: 2.5
                            )
                        }
                        if let percent = mix.matchPercent, mix.isSocial {
                            Text("\(percent)%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.black.opacity(0.55))
                                )
                                .padding(10)
                        }
                    }
                }
                .buttonStyle(PremiumPressStyle())
                .disabled(loadingMixID != nil)
                .accessibilityLabel(mix.title)
                .modifier(SelectedTraitModifier(isSelected: isSelected))

                Button {
                    selectVKMix(mix, andPlay: true)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.black)
                        .background(.white, in: Circle())
                        .minimumHitTarget(visualSize: 30)
                }
                .buttonStyle(PremiumPressStyle())
                .padding(8)
                .disabled(loadingMixID != nil)
                .accessibilityLabel(L10n.text("play_mix"))
                .accessibilityValue(mix.title)
            }

            Button {
                selectVKMix(mix)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mix.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            isSelected ? settings.theme.accent : .primary
                        )
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = trimmedText(cardSubtitle(for: mix)) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Text(mixTypeTitle(for: mix))
                        if !cachedTracks.isEmpty {
                            Text("·")
                            Text(L10n.trackCount(cachedTracks.count))
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(width: metrics.cardWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                selectVKMix(mix, andPlay: true)
            } label: {
                Label(L10n.text("play_mix"), systemImage: "play.fill")
            }
            Button {
                selectVKMix(mix)
            } label: {
                Label(L10n.text("open_here"), systemImage: "list.bullet")
            }
        }
    }

    @ViewBuilder
    private func vkMagazineShelves(metrics: MixHubMetrics) -> some View {
        if !officialShelves.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PremiumSectionHeader(
                    L10n.text("vk_mix_magazine"),
                    subtitle: L10n.text(
                        "catalog_shelves_with_quick_launch_and_track_previews"
                    )
                )

                ForEach(officialShelves.prefix(6), id: \.title) { shelf in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shelf.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    L10n.format(
                                        "d0_mixes",
                                        shelf.mixes.count
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button {
                                openVibeShelf(shelf)
                            } label: {
                                Text(L10n.text("open"))
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(
                                alignment: .top,
                                spacing: metrics.cardSpacing
                            ) {
                                ForEach(shelf.mixes.prefix(8)) { mix in
                                    vkShelfCard(mix, metrics: metrics)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .premiumCard()
                }
            }
            .padding(.top, 4)
        }
    }

    private func vkShelfCard(
        _ mix: MusicMix,
        metrics: MixHubMetrics
    ) -> some View {
        let cached = vkTrackCache[mix.id] ?? []
        let artTracks = cached.isEmpty ? homeCatalog.recommendations : cached
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                selectVKMix(mix)
            } label: {
                MixArtworkView(
                    mix: mix,
                    tracks: artTracks,
                    size: metrics.cardWidth,
                    height: metrics.cardHeight,
                    cornerRadius: PremiumLayout.compactRadius
                )
                .overlay(alignment: .topLeading) {
                    Text(mixTypeTitle(for: mix))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.black.opacity(0.5))
                        )
                        .padding(8)
                }
            }
            .buttonStyle(PremiumPressStyle())
            .disabled(loadingMixID != nil)

            Text(mix.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = trimmedText(cardSubtitle(for: mix)) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cached.isEmpty {
                Text(L10n.trackCount(cached.count))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    selectVKMix(mix, andPlay: true)
                } label: {
                    Label(L10n.text("listen"), systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .minimumHitTarget(visualSize: 28)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    selectVKMix(mix)
                } label: {
                    Label(L10n.text("open"), systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                        .minimumHitTarget(visualSize: 28)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(width: metrics.cardWidth, alignment: .leading)
        .contextMenu {
            Button {
                selectVKMix(mix, andPlay: true)
            } label: {
                Label(L10n.text("play_mix"), systemImage: "play.fill")
            }
            Button {
                selectVKMix(mix)
            } label: {
                Label(L10n.text("open_here"), systemImage: "list.bullet")
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var listenLaterBanner: some View {
        if let pin = pinnedMixStore.pin, !pin.tracks.isEmpty {
            Button {
                resumePinned(pin)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtwork(url: pin.artworkURL, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("listen_later"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pin.mixTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            L10n.format(
                                "d0_tracks_resume",
                                pin.tracks.count
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.controlRadius,
                        style: .continuous
                    )
                    .fill(.primary.opacity(0.06))
                )
            }
            .buttonStyle(PremiumPressStyle())
            .contextMenu {
                Button { resumePinned(pin) } label: {
                    Label(L10n.text("resume"), systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    pinnedMixStore.clear()
                } label: {
                    Label(L10n.text("remove"), systemImage: "bookmark.slash")
                }
            }
            .accessibilityLabel(L10n.text("listen_later"))
            .accessibilityValue(
                "\(pin.mixTitle), \(L10n.trackCount(pin.tracks.count))"
            )
        }
    }

    private func playHero(
        mix: MusicMix,
        tracks: [Track],
        metrics: MixHubMetrics,
        subtitle: String
    ) -> some View {
        let artSource = tracks.isEmpty
            ? homeCatalog.recommendations
            : tracks
        let trimmedSubtitle = trimmedText(subtitle)
        // One composition, one primary verb: the play circle is the
        // control. The hero itself is not a Button — nesting a curator
        // link inside another button's label made that link unreachable
        // to both touch and VoiceOver.
        return ZStack(alignment: .bottomLeading) {
            MixArtworkView(
                mix: mix,
                tracks: artSource,
                size: metrics.contentWidth,
                height: metrics.heroHeight,
                cornerRadius: 0
            )
            .overlay {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.05),
                        Color.black.opacity(0.55),
                        Color.black.opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                if let curator = mix.curator, curator.isUsable {
                    Button {
                        selectedCurator = curator
                    } label: {
                        Text(curator.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .textCase(.uppercase)
                            .tracking(0.55)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.text("open_here"))
                } else if mix.id == MusicMix.common.id {
                    Text(L10n.text("personal_mix"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .textCase(.uppercase)
                        .tracking(0.55)
                } else if mix.isSocial {
                    Text(L10n.text("social_mix"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .textCase(.uppercase)
                        .tracking(0.55)
                }
                Text(mix.title)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let trimmedSubtitle {
                    Text(trimmedSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .padding(.trailing, 72)

            Button {
                start(mix)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 52, height: 52)
                    .background(.white, in: Circle())
            }
            .buttonStyle(PremiumPressStyle())
            .disabled(loadingMixID != nil)
            .accessibilityLabel(L10n.text("play_mix"))
            .accessibilityValue(mix.title)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
            .padding(18)
        }
        .foregroundStyle(.white)
        .frame(minHeight: metrics.heroHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.cardRadius,
                style: .continuous
            )
        )
        .overlay {
            if loadingMixID == mix.id {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.28))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                    )
            }
        }
        .contextMenu {
            Button { start(mix) } label: {
                Label(L10n.text("play_mix"), systemImage: "play.fill")
            }
            Button {
                shuffle(mix)
            } label: {
                Label(L10n.text("shuffle"), systemImage: "shuffle")
            }
            .disabled(tracks.isEmpty)
            Button {
                pin(mix: mix, tracks: tracks)
            } label: {
                Label(L10n.text("listen_later"), systemImage: "bookmark")
            }
            .disabled(tracks.isEmpty || !player.isPlaying(mix))
            if let seed = tracks.first {
                TrackMixActions.menuButtons(
                    for: seed,
                    environment: environment,
                    includeDislike: false
                )
            }
        }
    }

    private func mixMetadataStrip(
        mix: MusicMix,
        tracks: [Track]
    ) -> some View {
        let stats = MixListeningStats(
            tracks: tracks,
            history: history.entries
        )
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                metadataChip(
                    mixTypeTitle(for: mix),
                    systemImage: mixTypeIcon(for: mix),
                    highlighted: true
                )
                if !tracks.isEmpty {
                    metadataChip(
                        L10n.trackCount(tracks.count),
                        systemImage: "music.note.list"
                    )
                    metadataChip(
                        stats.duration.formattedDuration,
                        systemImage: "clock"
                    )
                    metadataChip(
                        L10n.format("d0_novelty", stats.noveltyPercent),
                        systemImage: "sparkles"
                    )
                }
                if let percent = mix.matchPercent {
                    metadataChip(
                        L10n.format("d0_match", percent),
                        systemImage: "person.2"
                    )
                }
                ForEach(stats.topArtists.prefix(4), id: \.self) { artist in
                    metadataChip(
                        artist,
                        systemImage: "music.mic",
                        compact: true
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func metadataChip(
        _ title: String,
        systemImage: String,
        highlighted: Bool = false,
        compact: Bool = false
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .foregroundStyle(highlighted ? settings.theme.accent : .primary)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        highlighted
                            ? settings.theme.accent.opacity(0.14)
                            : Color.primary.opacity(0.06)
                    )
            )
    }

    private func rationaleBlock(
        _ rationale: MixRationale,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(rationale.lines, id: \.self) { line in
                Text("· \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func controlsPanel(
        mix: MusicMix,
        tracks: [Track]
    ) -> some View {
        let selectedMode = player.mixRadioMode
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("mix_radio"))
                .font(.headline)

            // One line, not a static paragraph explaining the whole
            // feature every time the card renders: the caption already
            // changes with the selected mode, which is the part worth
            // reading.
            Picker(
                L10n.text("mode"),
                selection: Binding(
                    get: { player.mixRadioMode },
                    set: { applyRadio($0, mix: mix) }
                )
            ) {
                ForEach(MixRadioMode.allCases) { mode in
                    Text(mode.compactTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Label(selectedMode.caption, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Selena already has the rich wave card in `selenaWaveCard` —
            // a second identical door on the same screen is noise.
            if mix.id != MusicMix.common.id {
                mixConfigureEntry
            }

            // Hero owns Play. This row is shuffle + keep/hide only —
            // a second "Play all" next to the play circle was the same
            // verb twice on one card.
            HStack(spacing: 10) {
                Button {
                    shuffle(mix)
                } label: {
                    Label(
                        L10n.text("shuffle"),
                        systemImage: "shuffle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .disabled(loadingMixID != nil || tracks.isEmpty)

                Button {
                    pin(mix: mix, tracks: tracks)
                } label: {
                    Label(
                        pinnedMixStore.pin?.mixID == mix.id
                            ? L10n.text("saved")
                            : L10n.text("action.save"),
                        systemImage: pinnedMixStore.pin?.mixID == mix.id
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .disabled(tracks.isEmpty || !player.isPlaying(mix))

                Menu {
                    Button(role: .destructive) {
                        hideFirstLoadedTrack(
                            in: mix,
                            tracks: tracks,
                            includeArtist: false
                        )
                    } label: {
                        Label(
                            L10n.text("hide_first_track"),
                            systemImage: "hand.thumbsdown"
                        )
                    }
                    Button(role: .destructive) {
                        hideFirstLoadedTrack(
                            in: mix,
                            tracks: tracks,
                            includeArtist: true
                        )
                    } label: {
                        Label(
                            L10n.text("hide_first_track_artist"),
                            systemImage: "person.badge.minus"
                        )
                    }
                } label: {
                    Label(
                        L10n.text("dislike"),
                        systemImage: "hand.thumbsdown"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .disabled(tracks.isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    /// Filters, hidden tracks and the queue are utility links, not radio
    /// tuning — folding them into the Radio Mix card was exactly the kind
    /// of unrelated content that made it read as half the screen. Flat
    /// row, no card: they don't need their own surface to be reachable.
    private func mixUtilityLinks(mix: MusicMix, tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                NavigationLink {
                    MixFeedbackManagerView()
                } label: {
                    Label(
                        L10n.text("hidden"),
                        systemImage: "eye.slash"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(minHeight: PremiumLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }

                Button {
                    openQueue(mix)
                } label: {
                    Label(
                        L10n.text("player.queue"),
                        systemImage: "list.bullet"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(minHeight: PremiumLayout.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .disabled(tracks.isEmpty)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var mixConfigureEntry: some View {
        Button {
            showingMixConfigure = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                Text(L10n.text("configure_mix"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hasActiveMixFilters {
                    Text(configuredMixSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel(L10n.text("configure_mix"))
        .accessibilityHint(L10n.text("configure_mix_accessibility_hint"))
    }

    private var hasActiveMixFilters: Bool {
        let languageActive = settings.mixLanguagePreference != .any
            && settings.mixLanguagePreference != .instrumental
        return languageActive || settings.mixFamiliarityPreference != .any
    }

    private func tracksBlock(
        mix: MusicMix,
        tracks: [Track],
        subtitle: String,
        metrics: MixHubMetrics
    ) -> some View {
        let preview = Array(tracks.prefix(defaultPreviewTrackLimit))
        let remainder = Array(tracks.dropFirst(defaultPreviewTrackLimit))
        let isExpanded = expandedTrackMixIDs.contains(mix.id)
        let expandedList = Array(
            remainder.prefix(
                max(0, expandedPreviewTrackLimit - defaultPreviewTrackLimit)
            )
        )
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                PremiumSectionHeader(
                    L10n.text("for_you"),
                    subtitle: subtitle
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(preview) { track in
                            trackCard(
                                track,
                                mix: mix,
                                queue: tracks,
                                width: metrics.trackWidth
                            )
                        }
                    }
                }
            }

            if !remainder.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PremiumSectionHeader(
                            L10n.text("continue_selection"),
                            subtitle: L10n.format(
                                "d0_more_in_queue",
                                remainder.count
                            )
                        )
                        Spacer(minLength: 12)
                        if isExpanded {
                            trackLayoutToggle
                        }
                        Button {
                            toggleTrackExpansion(for: mix)
                        } label: {
                            Text(
                                isExpanded
                                    ? L10n.text("collapse")
                                    : L10n.text("show_more")
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }

                    if isExpanded {
                        switch trackListLayout {
                        case .list:
                            // Flat, like every other long track list in the
                            // app (Library's own list has no enclosing
                            // card either) — up to 45 rows inside one
                            // rounded rectangle read as a modal card
                            // stapled onto the page, not as a list.
                            VStack(spacing: 0) {
                                ForEach(
                                    Array(expandedList.enumerated()),
                                    id: \.element.id
                                ) { index, track in
                                    TrackRow(
                                        track: track,
                                        queue: tracks,
                                        source: .catalogMix(mix)
                                    )
                                    .padding(.vertical, 7)
                                    if index < expandedList.count - 1 {
                                        Divider().padding(.leading, 64)
                                    }
                                }
                            }
                        case .grid:
                            LazyVGrid(
                                columns: metrics.gridColumns,
                                spacing: 10
                            ) {
                                ForEach(expandedList) { track in
                                    trackGridCell(
                                        track,
                                        mix: mix,
                                        queue: tracks,
                                        width: metrics.gridCellWidth
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var trackLayoutToggle: some View {
        Button {
            trackListLayout = trackListLayout == .list ? .grid : .list
            Haptics.selection()
        } label: {
            Image(
                systemName: trackListLayout == .list
                    ? "square.grid.2x2"
                    : "list.bullet"
            )
            .font(.caption.weight(.semibold))
            .minimumHitTarget(visualSize: 28, in: Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(L10n.text("toggle_list_layout"))
    }

    private func trackGridCell(
        _ track: Track,
        mix: MusicMix,
        queue: [Track],
        width: CGFloat
    ) -> some View {
        Button {
            playTrack(track, queue: queue, mix: mix)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    AsyncArtwork(url: track.artworkURL, size: 44)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous
                            )
                        )
                    if highlight.isCurrent(track.id) {
                        PlaybackIndicatorView(
                            isPlaying: highlight.isPlaying,
                            color: .white
                        )
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.4), in: Circle())
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = trimmedText(track.title) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    if let artist = trimmedText(track.artist) {
                        Text(artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(track.duration.formattedDuration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.05))
            )
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button { player.playNext(track) } label: {
                Label(L10n.text("play_next"), systemImage: "text.badge.plus")
            }
            Button { player.playLast(track) } label: {
                Label(L10n.text("play_last"),
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }
            TrackMixActions.menuButtons(
                for: track,
                environment: environment
            )
        }
    }

    private func trackCard(
        _ track: Track,
        mix: MusicMix,
        queue: [Track],
        width: CGFloat
    ) -> some View {
        Button {
            playTrack(track, queue: queue, mix: mix)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncArtwork(url: track.artworkURL, size: width)
                        .overlay(alignment: .topTrailing) {
                            LikedTrackBadge(
                                track: track,
                                style: .artwork
                            )
                            .padding(8)
                        }
                    Group {
                        if highlight.isCurrent(track.id) {
                            PlaybackIndicatorView(
                                isPlaying: highlight.isPlaying,
                                color: .black
                            )
                        } else {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(.white, in: Circle())
                    .padding(8)
                }
                if let title = trimmedText(track.title) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let artist = trimmedText(track.artist) {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(track.duration.formattedDuration)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button { player.playNext(track) } label: {
                Label(L10n.text("play_next"), systemImage: "text.badge.plus")
            }
            Button { player.playLast(track) } label: {
                Label(L10n.text("play_last"),
                    systemImage: "text.line.last.and.arrowtriangle.forward"
                )
            }
            Button {
                playTrack(track, queue: queue, mix: mix)
                player.presentPlayer()
            } label: {
                Label(L10n.text("open_player"), systemImage: "play.circle")
            }
            TrackMixActions.menuButtons(
                for: track,
                environment: environment
            )
            Button { sharingTrack = track } label: {
                Label(L10n.text("share_audio_file"),
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private func selenaStationSummary(metrics: MixHubMetrics) -> some View {
        let stats = MixListeningStats(
            tracks: selenaTracks,
            history: history.entries
        )
        let seeds = recentSeedTracks
        return VStack(alignment: .leading, spacing: 12) {
            PremiumSectionHeader(
                L10n.text("selena.personal_station"),
                subtitle: L10n.text(
                    "decoder_dev_s_neural_network_refreshes_the_window_from_history_recommend"
                )
            )

            LazyVGrid(
                columns: metrics.gridColumns,
                spacing: 10
            ) {
                stationStatCard(
                    title: L10n.text("in_window"),
                    value: L10n.trackCount(selenaTracks.count),
                    systemImage: "music.note.list"
                )
                stationStatCard(
                    title: L10n.text("duration"),
                    value: stats.duration.formattedDuration,
                    systemImage: "clock"
                )
                stationStatCard(
                    title: L10n.text("new_artists"),
                    value: "\(stats.noveltyPercent)%",
                    systemImage: "sparkles"
                )
                stationStatCard(
                    title: L10n.text("artists_2"),
                    value: String(stats.artistCount),
                    systemImage: "music.mic"
                )
            }

            if !stats.topArtists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stats.topArtists.prefix(6), id: \.self) {
                            artist in
                            metadataChip(
                                artist,
                                systemImage: "music.mic",
                                compact: true
                            )
                        }
                    }
                }
            }

            if !seeds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("recent_seeds"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(seeds) { track in
                                Button {
                                    Task {
                                        await environment.startMixFromTrack(
                                            track
                                        )
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        AsyncArtwork(
                                            url: track.artworkURL,
                                            size: 34
                                        )
                                        VStack(
                                            alignment: .leading,
                                            spacing: 1
                                        ) {
                                            if let title = trimmedText(
                                                track.title
                                            ) {
                                                Text(title)
                                                    .font(
                                                        .caption.weight(.semibold)
                                                    )
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                            }
                                            if let artist = trimmedText(
                                                track.artist
                                            ) {
                                                Text(artist)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .frame(
                                        width: max(
                                            170,
                                            metrics.contentWidth * 0.46
                                        ),
                                        alignment: .leading
                                    )
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: 14,
                                            style: .continuous
                                        )
                                        .fill(.primary.opacity(0.05))
                                    )
                                }
                                .buttonStyle(PremiumPressStyle())
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func stationStatCard(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(settings.theme.accent)
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
    }

    private var selenaQuickStarts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("how_to_start"))
                .font(.headline)
            Text(
                L10n.text(
                    "what_the_official_vk_music_app_calls_a_mix_from_your_music_and_a_mix_fro"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Hero already starts Selena — no second identical chip.
                    quickStartChip(
                        title: L10n.text("from_my_music"),
                        systemImage: "music.note.list"
                    ) {
                        Task { await environment.startMixFromMyMusic() }
                    }
                    quickStartChip(
                        title: L10n.text("mix_from_track"),
                        systemImage: "dot.radiowaves.up.forward"
                    ) {
                        if let seed = history.entries.first?.track
                            ?? selenaTracks.first {
                            Task {
                                await environment.startMixFromTrack(seed)
                            }
                        } else {
                            actionError = L10n.text(
                                "at_least_one_recent_track_is_required"
                            )
                        }
                    }
                    quickStartChip(
                        title: L10n.text("more_novelty"),
                        systemImage: "shuffle"
                    ) {
                        start(personalMix, applying: .moreNovel)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func quickStartChip(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(loadingMixID != nil)
    }

    private func vibeShelfBlock(metrics: MixHubMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("vibes_from_vk"))
                .font(.headline)
            Text(
                L10n.text(
                    "moods_and_themed_shelves_from_the_catalog_just_like_in_the_vk_app"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.cardSpacing) {
                    ForEach(vibeShelves, id: \.title) { shelf in
                        Button {
                            openVibeShelf(shelf)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(shelf.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    L10n.format(
                                        "d0_mixes",
                                        shelf.mixes.count
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(
                                width: metrics.cardWidth,
                                alignment: .leading
                            )
                            .padding(12)
                            .premiumCard()
                        }
                        .buttonStyle(PremiumPressStyle())
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var personalMix: MusicMix {
        mixes.first(where: { $0.id == MusicMix.common.id }) ?? .common
    }

    private var vkMixes: [MusicMix] {
        mixes.filter { $0.id != MusicMix.common.id }
    }

    private var orderedVKMixes: [MusicMix] {
        var seen = Set<String>()
        var result: [MusicMix] = []
        let buckets: [[MusicMix]] = [
            vkMixes.filter(\.isSocial),
            officialShelves.flatMap(\.mixes),
            algorithmicMixes
        ]
        for bucket in buckets {
            for mix in bucket where seen.insert(mix.id).inserted {
                result.append(mix)
            }
        }
        for mix in vkMixes where seen.insert(mix.id).inserted {
            result.append(mix)
        }
        if let skip = deprioritizedMixID,
           skip != focusedMixID,
           let index = result.firstIndex(where: { $0.id == skip }) {
            let moved = result.remove(at: index)
            result.append(moved)
        }
        return result
    }

    private var officialShelves: [(title: String, mixes: [MusicMix])] {
        let candidates = vkMixes.filter {
            !$0.isSocial && ($0.sectionTitle?.isEmpty == false)
        }
        var order: [String] = []
        var grouped: [String: [MusicMix]] = [:]
        for mix in candidates {
            let title = mix.sectionTitle!
            if grouped[title] == nil {
                order.append(title)
                grouped[title] = []
            }
            grouped[title]?.append(mix)
        }
        return order.compactMap { title in
            guard let items = grouped[title], !items.isEmpty else {
                return nil
            }
            return (title, items)
        }
    }

    private var algorithmicMixes: [MusicMix] {
        let shelved = Set(officialShelves.flatMap(\.mixes).map(\.id))
        return vkMixes.filter { !$0.isSocial && !shelved.contains($0.id) }
    }

    private var vibeShelves: [(title: String, mixes: [MusicMix])] {
        officialShelves.filter {
            MixSeedRadio.looksLikeVibeShelf($0.title)
        }
    }

    private var selenaHeroSubtitle: String {
        if let name = sessionStore.profile?.firstName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("selena.prepared_for", name)
        }
        return L10n.text("selena.prepared_generic")
    }

    private func cardSubtitle(for mix: MusicMix) -> String {
        if let curator = mix.curator, curator.isUsable {
            if let percent = mix.matchPercent {
                return L10n.format(
                    "n_0_d1_match",
                    curator.displayName,
                    percent
                )
            }
            return curator.displayName
        }
        if mix.isSocial, let percent = mix.matchPercent {
            return L10n.format("match_with_your_taste_d0", percent)
        }
        if mix.isSocial {
            return L10n.text("match_with_your_taste")
        }
        if let section = mix.sectionTitle,
           !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return section
        }
        return mix.subtitle
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func vkTracksSubtitle(for mix: MusicMix) -> String {
        if mix.isSocial {
            return L10n.text("matched_from_overlapping_tastes")
        }
        if mix.sectionTitle != nil {
            return L10n.text("official_vk_selection")
        }
        return L10n.text("picked_by_vk_algorithms")
    }

    private func tracks(for mix: MusicMix) -> [Track] {
        if mix.id == MusicMix.common.id {
            return selenaTracks
        }
        if selectedVKMix?.id == mix.id {
            return vkTracks
        }
        return vkTrackCache[mix.id] ?? []
    }

    private var emptyMixesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L10n.text("only_your_personal_mix_is_available_right_now"))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(
                L10n.text(
                    "vk_has_not_prepared_themed_mixes_for_your_account_yet_check_back_later_o"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    hubTab = .selena
                } label: {
                    Text(L10n.text("open_selena"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text(L10n.text("action.refresh"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L10n.text("could_not_load_mixes"))
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load(force: true) }
            } label: {
                Text(L10n.text("action.refresh"))
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func skeleton(metrics: MixHubMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(
                cornerRadius: PremiumLayout.cardRadius,
                style: .continuous
            )
            .fill(.primary.opacity(0.08))
            .frame(height: metrics.heroHeight)
            RoundedRectangle(
                cornerRadius: PremiumLayout.controlRadius,
                style: .continuous
            )
            .fill(.primary.opacity(0.08))
            .frame(height: 96)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.cardSpacing) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(
                            cornerRadius: PremiumLayout.compactRadius,
                            style: .continuous
                        )
                        .fill(.primary.opacity(0.08))
                        .frame(
                            width: metrics.cardWidth,
                            height: metrics.cardHeight + 44
                        )
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel(L10n.text("loading_recommendations_and_mixes"))
    }

    private func actionErrorRow(_ message: String) -> some View {
        let isFilterNotice = message == L10n.text(
            "mix_filters_relaxed_to_keep_queue"
        )
        return Button { actionError = nil } label: {
            Label(
                message,
                systemImage: isFilterNotice
                    ? "info.circle"
                    : "exclamationmark.triangle"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func scrollHubToTop(proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(MainTabScrollDestination.mix, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo(
                    MainTabScrollDestination.mix,
                    anchor: .top
                )
            }
        }
    }

    private var recentSeedTracks: [Track] {
        var seen = Set<String>()
        return history.entries.compactMap { entry in
            let track = entry.track
            return seen.insert(track.id).inserted ? track : nil
        }
        .prefix(8)
        .map { $0 }
    }

    private func mixTypeTitle(for mix: MusicMix) -> String {
        if mix.id == MusicMix.common.id {
            return L10n.text("selena_station")
        }
        if mix.curator?.isUsable == true {
            return L10n.text("curated")
        }
        if mix.isSocial {
            return L10n.text("social")
        }
        if mix.sectionTitle != nil {
            return L10n.text("vk_shelf")
        }
        return L10n.text("vk_algorithms")
    }

    private func mixTypeIcon(for mix: MusicMix) -> String {
        if mix.id == MusicMix.common.id { return "sparkles" }
        if mix.curator?.isUsable == true { return "person.crop.circle" }
        if mix.isSocial { return "person.2" }
        if mix.sectionTitle != nil { return "rectangle.stack" }
        return "wand.and.stars"
    }

    private func toggleTrackExpansion(for mix: MusicMix) {
        if expandedTrackMixIDs.contains(mix.id) {
            expandedTrackMixIDs.remove(mix.id)
        } else {
            expandedTrackMixIDs.insert(mix.id)
        }
        Haptics.selection()
    }

    private func resumePinned(_ pin: PinnedMixSnapshot) {
        let mix = pin.mix
        if mix.id == MusicMix.common.id {
            hubTab = .selena
            // Pin holds the played (already filtered) queue — never treat
            // it as an unfiltered baseline or loosening filters cannot
            // recover dropped tracks.
            storeTracks(pin.tracks, for: mix, updatingBaseline: false)
        } else {
            hubTab = .vk
            applyVKSelection(
                resolvedVKMix(from: pin) ?? mix,
                tracks: pin.tracks
            )
        }
        let continuation = mixContinuationProvider(
            for: mix,
            knownTracks: pin.tracks
        )
        player.resumePinned(pin, continuation: continuation)
        // `resumePinned` replays through `play`, which resets the ordering,
        // so re-apply the pinned mode afterwards. Previously this only
        // restored the picker's appearance while the queue stayed unranked.
        if let saved = MixRadioMode(rawValue: pin.radioMode ?? ""),
           saved != .balanced {
            player.rerankUpcomingMix(
                mode: saved,
                historyArtists: Set(
                    history.entries.prefix(MixListeningHistoryWindow.ranking).map(\.track.artist)
                )
            )
        }
    }

    private func resolvedVKMix(from pin: PinnedMixSnapshot) -> MusicMix? {
        if let live = vkMixes.first(where: { $0.id == pin.mixID }) {
            return live
        }
        return nil
    }

    private func shuffle(_ mix: MusicMix) {
        let loaded = tracks(for: mix)
        guard loaded.count > 1 else {
            start(mix)
            return
        }
        player.playShuffled(
            in: loaded,
            continuation: mixContinuationProvider(
                for: mix,
                knownTracks: loaded
            ),
            source: .catalogMix(mix)
        )
        Haptics.selection()
    }

    private func openQueue(_ mix: MusicMix) {
        if player.isPlaying(mix), !player.queue.isEmpty {
            player.presentQueue()
        } else {
            start(mix)
            player.presentQueue()
        }
    }

    private func refilterLoadedTracks(for mix: MusicMix) {
        let base = baseTracks(for: mix)
        guard !base.isEmpty else {
            // No baseline yet — still tighten/loosen whatever is playing.
            environment.reapplyMixFiltersToPlayingQueue()
            return
        }
        storeTracks(base, for: mix)
        syncPlayingQueue(with: mix)
        Haptics.selection()
    }

    /// Filters must change what you hear, not only the list on screen.
    private func syncPlayingQueue(with mix: MusicMix) {
        guard player.isPlaying(mix),
              let current = player.currentTrack else { return }
        let cleaned = tracks(for: mix)
        if let index = cleaned.firstIndex(where: { $0.id == current.id }) {
            player.replaceUpcoming(
                with: Array(cleaned.suffix(from: index + 1))
            )
        } else {
            player.replaceUpcoming(with: cleaned)
        }
    }

    private func hideFirstLoadedTrack(
        in mix: MusicMix,
        tracks: [Track],
        includeArtist: Bool
    ) {
        guard let first = tracks.first else { return }
        environment.dislike(first, includeArtist: includeArtist)
        // Feedback (hide/dislike) should apply on top of the unfiltered
        // baseline, not on top of language/familiarity filtered caches.
        let base = baseTracks(for: mix)
        let cleaned = mixFeedbackStore.filtering(base)
        storeTracks(cleaned, for: mix)
    }

    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil else { return }
        let needsMixes = force || mixes.isEmpty
        let needsSelena = force || selenaTracks.isEmpty
        // The two used to share one guard on `mixes`, so a Selena fetch that
        // failed while the catalog succeeded could never be retried without
        // a manual pull-to-refresh.
        guard needsMixes || needsSelena else { return }
        isLoading = true
        defer { isLoading = false }
        // Pull-to-refresh must also refresh Home's personal recommendations —
        // otherwise Selena keeps composing from a stale cache while the
        // catalog shelves update.
        if force {
            await environment.refreshHomeCatalog(force: true)
        }
        // Selena is the tab everyone lands on, and its tracks come from the
        // recommendation stream — they do not read `mixes` at all. Fetching
        // them after the VK catalog meant the default tab sat on a skeleton
        // waiting for a request it never uses. Both run side by side now.
        let selena: Task<Void, Never>? =
            needsSelena
            ? Task { await loadSelenaTracks() }
            : nil
        do {
            if needsMixes {
                // Home already hydrated the same catalog — reuse it on a
                // cold Explore open instead of paying for catalogSnapshot
                // again before Selena can even paint.
                if !force, !homeCatalog.mixes.isEmpty {
                    mixes = homeCatalog.mixes
                    loadErrorMessage = nil
                } else {
                    mixes = try await environment.withAuthorizedToken {
                        token in
                        try await environment.musicService
                            .mixes(accessToken: token)
                    }
                    loadErrorMessage = nil
                }
                // VK track hydrate is for the VK tab. Doing it on Selena
                // land steals bandwidth from the recommendation stream.
                let shouldLoadVKTracks =
                    hubTab == .vk
                    || focusedMixID != nil
                    || startsOnVK
                ensureVKSelection(
                    forceReload: force,
                    loadTracks: shouldLoadVKTracks
                )
            }
        } catch is CancellationError {
            // The view went away or the token changed — drop the sibling
            // fetch too instead of letting it finish into a dead view.
            selena?.cancel()
            await selena?.value
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        await selena?.value
    }

    private func loadSelenaTracks() async {
        // Instant first paint when Home already has personal
        // recommendations — Explore used to sit on a skeleton until four
        // recommendation round-trips finished even though the same tracks
        // were already in memory.
        if selenaTracks.isEmpty, !homeCatalog.recommendations.isEmpty {
            let seeds = SelenaRecommendationComposer.seedTracks(
                history: history.entries,
                recommendations: homeCatalog.recommendations,
                loaded: []
            )
            let quick = SelenaRecommendationComposer.compose(
                seedTracks: seeds,
                personalRecommendations: homeCatalog.recommendations,
                similarRecommendations: [],
                diversity: settings.selenaDiversityPreference
            )
            if !quick.isEmpty {
                storeTracks(quick, for: personalMix)
            }
        }

        let cachedPersonal = homeCatalog.recommendations
        let stream = selenaRecommendationStream(knownTracks: [])
        do {
            let bootstrap = try await environment.withAuthorizedToken {
                token in
                try await stream.next(
                    accessToken: token,
                    musicService: environment.musicService,
                    cachedPersonalRecommendations: cachedPersonal,
                    diversity: settings.selenaDiversityPreference
                )
            }
            storeTracks(bootstrap, for: personalMix)
            MixBootstrapPrefetch.artwork(for: bootstrap)
            trackLoadTask?.cancel()
            trackLoadTask = Task {
                do {
                    let more = try await environment.withAuthorizedToken {
                        token in
                        try await stream.next(
                            accessToken: token,
                            musicService: environment.musicService,
                            diversity: settings.selenaDiversityPreference
                        )
                    }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        let base = baseTracks(for: personalMix)
                        let merged = mergeUnfiltered(base, more)
                        storeTracks(merged, for: personalMix)
                    }
                } catch {}
            }
        } catch is CancellationError {
            return
        } catch {
            // Catalog may still show shelves; Selena tracks retry on refresh.
        }
    }

    private func ensureVKSelection(
        forceReload: Bool = false,
        loadTracks: Bool = true
    ) {
        guard !orderedVKMixes.isEmpty else {
            selectedVKMix = nil
            vkTracks = []
            vkRationale = .empty
            return
        }
        let preferred =
            focusedMixID.flatMap { id in
                orderedVKMixes.first { $0.id == id }
            }
            ?? selectedVKMix.flatMap { current in
                orderedVKMixes.first { $0.id == current.id }
            }
            ?? pinnedMixStore.pin.flatMap { pin in
                orderedVKMixes.first { $0.id == pin.mixID }
            }
            ?? orderedVKMixes.first
        guard let mix = preferred else { return }
        if selectedVKMix?.id != mix.id {
            applyVKSelection(
                mix,
                tracks: vkTrackCache[mix.id],
                loadIfMissing: loadTracks
            )
        } else if forceReload || (loadTracks && vkTracks.isEmpty) {
            loadVKTracks(mix)
        }
    }

    private func selectVKMix(_ mix: MusicMix, andPlay: Bool = false) {
        let changed = selectedVKMix?.id != mix.id
        if changed {
            Haptics.selection()
            selectedVKMix = mix
            if let cached = vkTrackCache[mix.id], !cached.isEmpty {
                vkTracks = cached
                vkRationale = vkRationaleCache[mix.id]
                    ?? MixRationaleBuilder.build(
                        mixTracks: cached,
                        history: history.entries,
                        recommendations: homeCatalog.recommendations
                    )
            } else {
                vkTracks = []
                vkRationale = .empty
            }
        }
        if andPlay {
            start(mix)
        } else if changed, vkTracks.isEmpty {
            loadVKTracks(mix)
        }
    }

    private func applyVKSelection(
        _ mix: MusicMix,
        tracks: [Track]?,
        loadIfMissing: Bool = true
    ) {
        selectedVKMix = mix
        if let tracks, !tracks.isEmpty {
            // One writer for display + baseline caches — never assign the
            // filtered/played list into the unfiltered baseline.
            storeTracks(tracks, for: mix, updatingBaseline: false)
        } else {
            vkTracks = []
            vkRationale = .empty
            if loadIfMissing {
                loadVKTracks(mix)
            }
        }
    }

    private func loadVKTracks(_ mix: MusicMix) {
        trackLoadTask?.cancel()
        loadingMixID = mix.id
        let cursor = MixTrackContinuationCursor(mix: mix)
        trackLoadTask = Task {
            defer {
                if loadingMixID == mix.id {
                    loadingMixID = nil
                }
            }
            do {
                let bootstrap = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksBootstrap(
                        mix,
                        accessToken: token
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    storeTracks(bootstrap, for: mix)
                    MixBootstrapPrefetch.artwork(for: bootstrap)
                }
                let more = try await environment.withAuthorizedToken { token in
                    try await cursor.next(
                        accessToken: token,
                        musicService: environment.musicService
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    let base = baseTracks(for: mix)
                    let seed = base.isEmpty ? tracks(for: mix) : base
                    storeTracks(
                        mergeUnfiltered(seed, more),
                        for: mix
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func start(
        _ mix: MusicMix,
        applying mode: MixRadioMode? = nil
    ) {
        guard sessionStore.accessToken != nil else { return }
        if mix.id != MusicMix.common.id, selectedVKMix?.id != mix.id {
            selectVKMix(mix)
        }
        if mix.id == MusicMix.common.id {
            // Fresh Selena sit-down: clear session spacing so the bandit
            // decision matches this queue, not an older Home/Explore run.
            environment.resetSelenaExposure()
        }
        // If the mix was already bootstrapped under different filter
        // settings, refresh the cached queue from the unfiltered baseline.
        let base = baseTracks(for: mix)
        if !base.isEmpty {
            storeTracks(base, for: mix)
        }
        let loaded = tracks(for: mix)
        let queueToPlay: [Track]
        if mix.id == MusicMix.common.id {
            // Re-rank under the reset exposure so the list on screen and
            // the queue that starts are the same order.
            let ranked = environment.rankSelenaQueue(loaded)
            selenaTracks = ranked
            queueToPlay = ranked
        } else {
            queueToPlay = loaded
        }
        if let first = queueToPlay.first {
            playTrack(first, queue: queueToPlay, mix: mix, applying: mode)
            return
        }
        loadingMixID = mix.id
        launchTask?.cancel()
        launchTask = Task {
            defer { loadingMixID = nil }
            do {
                let bootstrap = try await bootstrapTracks(for: mix)
                guard !Task.isCancelled else { return }
                MixBootstrapPrefetch.artwork(for: bootstrap)
                storeTracks(bootstrap, for: mix)
                let initialQueue = mix.id == MusicMix.common.id
                    ? environment.filteredSelenaTracks(bootstrap)
                    : environment.filteredMixTracks(bootstrap)
                guard !initialQueue.isEmpty else { return }

                let queue: [Track] = if mix.id == MusicMix.common.id {
                    await MainActor.run {
                        environment.rankSelenaQueue(initialQueue)
                    }
                } else {
                    initialQueue
                }

                guard !Task.isCancelled else { return }
                guard let started = queue.first else { return }
                playTrack(started, queue: queue, mix: mix, applying: mode)
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func bootstrapTracks(for mix: MusicMix) async throws -> [Track] {
        if mix.id == MusicMix.common.id {
            let stream = selenaRecommendationStream(knownTracks: [])
            return try await environment.withAuthorizedToken { token in
                try await stream.next(
                    accessToken: token,
                    musicService: environment.musicService,
                    cachedPersonalRecommendations: homeCatalog.recommendations,
                    diversity: settings.selenaDiversityPreference
                )
            }
        }
        return try await environment.withAuthorizedToken { token in
            try await environment.musicService.mixTracksBootstrap(
                mix,
                accessToken: token
            )
        }
    }

    private func playTrack(
        _ track: Track,
        queue: [Track],
        mix: MusicMix,
        applying mode: MixRadioMode? = nil
    ) {
        player.play(
            track,
            in: queue,
            continuation: mixContinuationProvider(
                for: mix,
                knownTracks: queue
            ),
            source: .catalogMix(mix)
        )
        // `play` resets the ordering for the fresh queue; re-apply when the
        // user got here by choosing a mode rather than pressing play.
        if let mode, mode != .balanced {
            applyRadio(mode, mix: mix)
        }
    }

    private func mixContinuationProvider(
        for mix: MusicMix,
        knownTracks: [Track]
    ) -> () async throws -> [Track] {
        if mix.id == MusicMix.common.id {
            let stream = selenaRecommendationStream(knownTracks: knownTracks)
            return {
                let more = try await environment.withAuthorizedToken { token in
                    try await stream.next(
                        accessToken: token,
                        musicService: environment.musicService,
                        diversity: settings.selenaDiversityPreference
                    )
                }
                return await MainActor.run {
                    environment.selenaContinuationTracks(more)
                }
            }
        }

        let cursor = MixTrackContinuationCursor(mix: mix)
        return {
            let more = try await environment.withAuthorizedToken { token in
                try await cursor.next(
                    accessToken: token,
                    musicService: environment.musicService
                )
            }
            return await MainActor.run {
                environment.continuationTracks(more)
            }
        }
    }

    private func selenaRecommendationStream(
        knownTracks: [Track]
    ) -> SelenaRecommendationCursor {
        let recent = history.entries
            .prefix(MixListeningHistoryWindow.ranking)
            .map(\.track)
        return SelenaRecommendationCursor(
            seedTracks: SelenaRecommendationComposer.seedTracks(
                history: history.entries,
                recommendations: homeCatalog.recommendations,
                loaded: knownTracks.isEmpty ? selenaTracks : knownTracks
            ),
            knownTracks: knownTracks + recent
        )
    }

    private func storeTracks(
        _ tracks: [Track],
        for mix: MusicMix,
        updatingBaseline: Bool = true,
        applyBanditPreview: Bool = true
    ) {
        let cleaned: [Track]
        if mix.id == MusicMix.common.id {
            cleaned = environment.filteredSelenaTracks(tracks)
        } else {
            cleaned = environment.filteredMixTracks(tracks)
        }
        let display: [Track]
        if mix.id == MusicMix.common.id, applyBanditPreview {
            // Preview must match play order — bandit without burning
            // exposure until the listener actually starts the station.
            display = environment.rankSelenaQueue(
                cleaned,
                recordExposure: false
            )
        } else {
            display = cleaned
        }
        let rationale = MixRationaleBuilder.build(
            mixTracks: display,
            history: history.entries,
            recommendations: homeCatalog.recommendations
        )
        if mix.id == MusicMix.common.id {
            if updatingBaseline {
                selenaTrackBase = tracks
            }
            selenaTracks = display
            selenaRationale = rationale
            return
        }
        if updatingBaseline {
            vkTrackBaseCache[mix.id] = tracks
        }
        vkTrackCache[mix.id] = cleaned
        vkRationaleCache[mix.id] = rationale
        if selectedVKMix?.id == mix.id {
            vkTracks = cleaned
            vkRationale = rationale
        }
    }

    private func baseTracks(for mix: MusicMix) -> [Track] {
        if mix.id == MusicMix.common.id {
            return selenaTrackBase
        }
        return vkTrackBaseCache[mix.id] ?? []
    }

    private func currentMixForFilters() -> MusicMix? {
        // Prefer the mix that is actually playing — filters exist to shape
        // what you hear, not which tab happens to be visible.
        if let mixID = player.queueSource?.mixID {
            if personalMix.id == mixID { return personalMix }
            if let selected = selectedVKMix, selected.id == mixID {
                return selected
            }
            if let match = mixes.first(where: { $0.id == mixID }) {
                return match
            }
        }
        switch hubTab {
        case .selena:
            return personalMix
        case .vk:
            return selectedVKMix ?? orderedVKMixes.first ?? personalMix
        }
    }

    @MainActor
    private func startResolvedMood(_ mood: MixMoodPreference) {
        // Prefer Home's already-fetched mixes so a mood chip does not wait
        // on Explore's own Selena bootstrap + catalog round-trip.
        if mixes.isEmpty, !homeCatalog.mixes.isEmpty {
            mixes = homeCatalog.mixes
        }
        if mixes.isEmpty, sessionStore.accessToken != nil {
            launchTask?.cancel()
            launchTask = Task {
                await load()
                guard !Task.isCancelled else { return }
                await MainActor.run { finishResolvedMood(mood) }
            }
            return
        }
        finishResolvedMood(mood)
    }

    @MainActor
    private func finishResolvedMood(_ mood: MixMoodPreference) {
        switch MixMoodLaunchPolicy.resolve(mood: mood, in: mixes) {
        case let .mix(mix):
            hubTab = mix.id == MusicMix.common.id ? .selena : .vk
            start(mix)
        case .myMusic:
            hubTab = .selena
            launchTask?.cancel()
            launchTask = Task { await environment.startMixFromMyMusic() }
        }
    }

    private func pin(mix: MusicMix, tracks: [Track]) {
        // Pin stores the live playhead — saving a card that is not the
        // current queue would write another mix's index/elapsed into this
        // bookmark.
        guard player.isPlaying(mix), !tracks.isEmpty else { return }
        pinnedMixStore.pin(
            mix: mix,
            tracks: tracks,
            currentIndex: player.currentIndex ?? 0,
            elapsed: player.elapsedTime,
            radioMode: player.mixRadioMode
        )
        Haptics.success()
    }

    private func applyRadio(_ mode: MixRadioMode, mix: MusicMix) {
        // Radio describes the live queue for THIS mix only. A mode change on
        // another card must not reshuffle a different mix that is playing.
        guard player.isPlaying(mix),
              !player.queue.isEmpty else {
            start(mix, applying: mode)
            return
        }
        let artists = Set(history.entries.prefix(MixListeningHistoryWindow.ranking).map(\.track.artist))
        let current = tracks(for: mix)
        let queue = current.isEmpty ? player.queue : current
        guard let seed = player.currentTrack ?? queue.first else { return }

        if mix.id == MusicMix.common.id, mode == .balanced {
            // Selena "balanced" is the bandit, not MixQueueRanker's shuffle —
            // otherwise mode flips undo the spacing Explore already showed.
            let base = baseTracks(for: mix)
            let pool = base.isEmpty ? queue : base
            let ranked = environment.rankSelenaQueue(
                environment.filteredSelenaTracks(pool),
                recordExposure: false
            )
            storeTracks(
                ranked,
                for: mix,
                updatingBaseline: false,
                applyBanditPreview: false
            )
            if let current = player.currentTrack,
               let index = ranked.firstIndex(where: { $0.id == current.id }) {
                player.replaceUpcoming(
                    with: Array(ranked.suffix(from: index + 1))
                )
            } else {
                player.rerankUpcomingMix(mode: mode, historyArtists: artists)
            }
            return
        }

        player.rerankUpcomingMix(mode: mode, historyArtists: artists)
        storeTracks(
            MixQueueRanker.rerank(
                queue: queue,
                currentIndex: player.currentIndex ?? 0,
                seed: seed,
                mode: mode,
                historyArtists: artists
            ),
            for: mix,
            updatingBaseline: false,
            // Mode already shaped the list; don't let bandit reshuffle it.
            applyBanditPreview: false
        )
        // Server refill for closerToSeed / moreNovel is owned by AudioPlayer.
    }

    private func openVibeShelf(
        _ shelf: (title: String, mixes: [MusicMix])
    ) {
        guard let first = shelf.mixes.first else { return }
        hubTab = .vk
        selectVKMix(first)
        Haptics.selection()
    }

    private func mergeTracks(_ lhs: [Track], _ rhs: [Track]) -> [Track] {
        var known = Set(lhs.map(\.id))
        var result = lhs
        for track in rhs where known.insert(track.id).inserted {
            result.append(track)
        }
        return environment.filteredMixTracks(
            Array(result.prefix(MixTrackRequestPolicy.queueLimit))
        )
    }

    /// Merge for baseline caching: do **not** run language/familiarity
    /// filters here — otherwise switching filters back and forth will
    /// permanently shrink the pool.
    private func mergeUnfiltered(_ lhs: [Track], _ rhs: [Track]) -> [Track] {
        var known = Set(lhs.map(\.id))
        var result = lhs
        for track in rhs where known.insert(track.id).inserted {
            result.append(track)
        }
        return Array(result.prefix(MixTrackRequestPolicy.queueLimit))
    }
}

private struct MixHubWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MixHubMetrics {
    let width: CGFloat

    var horizontalPadding: CGFloat {
        AdaptiveLayout.horizontalPadding(for: width)
    }
    var cardSpacing: CGFloat { width <= 350 ? 10 : 12 }
    var heroHeight: CGFloat { width <= 350 ? 176 : 200 }
    var contentWidth: CGFloat { max(0, width - horizontalPadding * 2) }
    /// Phone keeps ~38% of the content width. iPad uses AdaptiveLayout
    /// so cards grow past the old phone cap without becoming full-width.
    var cardWidth: CGFloat {
        if AdaptiveLayout.isRegularWidth(width) {
            return AdaptiveLayout.shelfCardWidth(
                for: width,
                compactMax: 148,
                regularMax: AdaptiveLayout.regularCardWidthCap
            )
        }
        return max(136, contentWidth * 0.38)
    }
    var cardHeight: CGFloat { cardWidth }
    var trackWidth: CGFloat {
        AdaptiveLayout.shelfCardWidth(
            for: width,
            compactMax: 148,
            regularMax: AdaptiveLayout.regularCardWidthCap,
            fraction: 0.36,
            compactMin: 114
        )
    }
    var columnCount: Int {
        AdaptiveLayout.columnCount(for: width)
    }
    var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: columnCount
        )
    }
    var gridCellWidth: CGFloat {
        let columns = CGFloat(columnCount)
        return max(0, (contentWidth - 10 * (columns - 1)) / columns)
    }
}

private struct MixListeningStats {
    let duration: TimeInterval
    let topArtists: [String]
    let artistCount: Int
    let noveltyPercent: Int

    init(tracks: [Track], history: [ListeningHistoryEntry]) {
        duration = tracks.reduce(0) { $0 + max(0, $1.duration) }

        var displayArtists: [String: String] = [:]
        var counts: [String: Int] = [:]
        for track in tracks {
            let key = MixFeedbackPolicy.normalized(track.artist)
            guard !key.isEmpty else { continue }
            displayArtists[key] = displayArtists[key] ?? track.artist
            counts[key, default: 0] += 1
        }

        topArtists = counts.keys.sorted {
            let left = counts[$0] ?? 0
            let right = counts[$1] ?? 0
            if left != right { return left > right }
            return (displayArtists[$0] ?? $0) < (displayArtists[$1] ?? $1)
        }
        .compactMap { displayArtists[$0] }
        artistCount = counts.count

        let recentArtists = Set(
            history.prefix(MixListeningHistoryWindow.familiarity).map { entry in
                MixFeedbackPolicy.normalized(entry.track.artist)
            }
            .filter { !$0.isEmpty }
        )
        guard !counts.isEmpty else {
            noveltyPercent = 0
            return
        }
        let novelArtists = counts.keys.filter { !recentArtists.contains($0) }
        noveltyPercent = Int(
            (Double(novelArtists.count) / Double(counts.count) * 100)
                .rounded()
        )
    }
}

private struct SelectedTraitModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}
