import SwiftUI

/// Single Mix tab: Selena and VK share the same listening window.
/// VK mix switching happens inline — no browse/detail push.
struct MixesHubView: View {
    private enum HubTab: String, CaseIterable, Identifiable {
        case selena
        case vk

        var id: String { rawValue }

        var title: String {
            switch self {
            case .selena: L10n.text("Селена")
            case .vk: L10n.text("VK Миксы")
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var highlight: PlaybackHighlightModel
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @EnvironmentObject private var history: ListeningHistoryStore
    @EnvironmentObject private var pinnedMixStore: PinnedMixStore
    @EnvironmentObject private var mixFeedbackStore: MixFeedbackStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hubTab: HubTab = .selena
    @State private var mixes: [MusicMix] = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var loadingMixID: String?
    @State private var actionError: String?
    @State private var queueFillTask: Task<Void, Never>?
    @State private var trackLoadTask: Task<Void, Never>?
    @State private var seedRadioTask: Task<Void, Never>?

    @State private var selenaTracks: [Track] = []
    @State private var selenaRationale: MixRationale = .empty
    @State private var selectedVKMix: MusicMix?
    @State private var vkTracks: [Track] = []
    @State private var vkRationale: MixRationale = .empty
    @State private var vkTrackCache: [String: [Track]] = [:]
    @State private var vkRationaleCache: [String: MixRationale] = [:]
    @State private var sharingTrack: Track?
    @State private var selectedCurator: MixCurator?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let metrics = MixHubMetrics(width: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        titleHeader
                            .id(MainTabScrollDestination.mix)

                        Picker(L10n.text("Микс"), selection: $hubTab) {
                            ForEach(HubTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel(L10n.text("Раздел миксов"))

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
                    .padding(.bottom, 120)
                }
            }
            .onReceive(scrollCoordinator.$request) { request in
                guard request?.destination == .mix else { return }
                scrollHubToTop(proxy: proxy)
            }
        }
        .background(ThemeBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
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
        .onChange(of: hubTab) { tab in
            if tab == .vk {
                ensureVKSelection()
            }
        }
        .onReceive(environment.$mixActionError) { error in
            guard let error else { return }
            actionError = error
            environment.mixActionError = nil
        }
        .onDisappear {
            queueFillTask?.cancel()
            trackLoadTask?.cancel()
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
                rationaleTitle: L10n.text("Почему Селена"),
                heroSubtitle: selenaHeroSubtitle,
                tracksSubtitle: L10n.text(
                    "Подобрано по вашим прослушиваниям VK"
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
        selenaQuickStarts
            .premiumAppear(delay: 0.08)
        if !vibeShelves.isEmpty {
            vibeShelfBlock(metrics: metrics)
                .premiumAppear(delay: 0.12)
        }
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
                rationaleTitle: L10n.text("Почему этот микс"),
                heroSubtitle: cardSubtitle(for: mix),
                tracksSubtitle: vkTracksSubtitle(for: mix),
                metrics: metrics,
                picker: {
                    if orderedVKMixes.count > 1 {
                        vkMixPicker(selected: mix, metrics: metrics)
                    }
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
                .accessibilityLabel(L10n.text("Загружаем рекомендации и миксы"))
        } else {
            playHero(
                mix: mix,
                tracks: tracks,
                metrics: metrics,
                subtitle: heroSubtitle
            )
            .premiumAppear(delay: 0.02)

            if !rationale.isEmpty {
                rationaleBlock(rationale, title: rationaleTitle)
                    .premiumAppear(delay: 0.06)
            }

            controlsPanel(mix: mix, tracks: tracks)
                .premiumAppear(delay: 0.1)

            picker()

            if !tracks.isEmpty {
                tracksBlock(
                    mix: mix,
                    tracks: tracks,
                    subtitle: tracksSubtitle,
                    metrics: metrics
                )
                .premiumAppear(delay: 0.14)
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
                "Ваши VK Миксы",
                subtitle: "Тот же экран — просто смените подборку"
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
                }
                .buttonStyle(PremiumPressStyle())
                .padding(8)
                .disabled(loadingMixID != nil)
                .accessibilityLabel(L10n.text("Воспроизвести микс"))
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
                    Text(cardSubtitle(for: mix))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(width: metrics.cardWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                selectVKMix(mix, andPlay: true)
            } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
            Button {
                selectVKMix(mix)
            } label: {
                Label("Открыть здесь", systemImage: "list.bullet")
            }
        }
    }

    // MARK: - Chrome

    private var titleHeader: some View {
        Text(L10n.text("Микс"))
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var listenLaterBanner: some View {
        if let pin = pinnedMixStore.pin, !pin.tracks.isEmpty {
            Button {
                resumePinned(pin)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtwork(url: pin.artworkURL, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Слушать позже"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pin.mixTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            L10n.format(
                                "%d треков · продолжить",
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
                    Label("Продолжить", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    pinnedMixStore.clear()
                } label: {
                    Label("Убрать", systemImage: "bookmark.slash")
                }
            }
            .accessibilityLabel(L10n.text("Слушать позже"))
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
        return Button { start(mix) } label: {
            ZStack(alignment: .bottomLeading) {
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
                            settings.theme.accent.opacity(0.35),
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
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
                    } else if mix.id == MusicMix.common.id {
                        Text(L10n.text("Персональный микс"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .textCase(.uppercase)
                            .tracking(0.55)
                    } else if mix.isSocial {
                        Text(L10n.text("Социальный микс"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .textCase(.uppercase)
                            .tracking(0.55)
                    }
                    Text(mix.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .padding(.trailing, 72)

                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(settings.theme.accent)
                    .frame(width: 52, height: 52)
                    .background(.white, in: Circle())
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topTrailing
                    )
                    .padding(18)
            }
            .foregroundStyle(.white)
            .frame(height: metrics.heroHeight)
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
        }
        .buttonStyle(PremiumPressStyle())
        .disabled(loadingMixID != nil)
        .accessibilityLabel(L10n.text("Воспроизвести микс"))
        .accessibilityValue(mix.title)
        .contextMenu {
            Button { start(mix) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
            Button {
                pin(mix: mix, tracks: tracks)
            } label: {
                Label("Слушать позже", systemImage: "bookmark")
            }
            .disabled(tracks.isEmpty)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Радио микса"))
                .font(.headline)
            Text(
                L10n.text(
                    "Разбавляет очередь и при «Ближе к треку» / «Больше новизны» "
                        + "подтягивает рекомендации VK по текущему треку"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker(
                L10n.text("Режим"),
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

            HStack(spacing: 10) {
                Button { start(mix) } label: {
                    Label(
                        L10n.text("Слушать"),
                        systemImage: "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loadingMixID != nil)

                Button {
                    pin(mix: mix, tracks: tracks)
                } label: {
                    Label(
                        L10n.text("Слушать позже"),
                        systemImage: pinnedMixStore.pin?.mixID == mix.id
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .disabled(tracks.isEmpty)
            }

            NavigationLink {
                MixFiltersSettingsView()
            } label: {
                Label(
                    L10n.text("Фильтры микса"),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func tracksBlock(
        mix: MusicMix,
        tracks: [Track],
        subtitle: String,
        metrics: MixHubMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                PremiumSectionHeader("Для вас", subtitle: subtitle)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(tracks.prefix(12)) { track in
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

            let list = Array(tracks.dropFirst(12).prefix(36))
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PremiumSectionHeader("Продолжить поток")
                    VStack(spacing: 0) {
                        ForEach(
                            Array(list.enumerated()),
                            id: \.element.id
                        ) { index, track in
                            TrackRow(
                                track: track,
                                queue: tracks,
                                source: .mix(title: mix.title)
                            )
                            .padding(.vertical, 7)
                            if index < list.count - 1 {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .premiumCard()
                }
            }
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
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button { player.playNext(track) } label: {
                Label("Играть следующим", systemImage: "text.badge.plus")
            }
            Button {
                playTrack(track, queue: queue, mix: mix)
                player.presentPlayer()
            } label: {
                Label("Открыть плеер", systemImage: "play.circle")
            }
            TrackMixActions.menuButtons(
                for: track,
                environment: environment
            )
            Button { sharingTrack = track } label: {
                Label(
                    "Поделиться аудиофайлом",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private var selenaQuickStarts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Как начать"))
                .font(.headline)
            Text(
                L10n.text(
                    "То, что в официальном VK Music зовут миксом по музыке и по треку"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    quickStartChip(
                        title: L10n.text("Селена"),
                        systemImage: "sparkles"
                    ) {
                        start(personalMix)
                    }
                    quickStartChip(
                        title: L10n.text("По моей музыке"),
                        systemImage: "music.note.list"
                    ) {
                        Task { await environment.startMixFromMyMusic() }
                    }
                    quickStartChip(
                        title: L10n.text("Микс по треку"),
                        systemImage: "dot.radiowaves.up.forward"
                    ) {
                        if let seed = history.entries.first?.track
                            ?? selenaTracks.first {
                            Task {
                                await environment.startMixFromTrack(seed)
                            }
                        } else {
                            actionError = L10n.text(
                                "Нужен хотя бы один недавний трек"
                            )
                        }
                    }
                    quickStartChip(
                        title: L10n.text("Больше новизны"),
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
            Text(L10n.text("Вайбы из VK"))
                .font(.headline)
            Text(
                L10n.text(
                    "Настроения и тематические полки из каталога — как в приложении VK"
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
                                Text(
                                    L10n.format(
                                        "%d миксов",
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
            return L10n.format("Селена подготовила подборку для %@", name)
        }
        return L10n.text("Селена подготовила подборку специально для вас")
    }

    private func cardSubtitle(for mix: MusicMix) -> String {
        if let curator = mix.curator, curator.isUsable {
            if let percent = mix.matchPercent {
                return L10n.format(
                    "%@ · совпадение %d%%",
                    curator.displayName,
                    percent
                )
            }
            return curator.displayName
        }
        if mix.isSocial, let percent = mix.matchPercent {
            return L10n.format("совпадение с вашим вкусом · %d%%", percent)
        }
        if mix.isSocial {
            return L10n.text("совпадение с вашим вкусом")
        }
        if let section = mix.sectionTitle,
           !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return section
        }
        return mix.subtitle
    }

    private func vkTracksSubtitle(for mix: MusicMix) -> String {
        if mix.isSocial {
            return L10n.text("Подобрано по пересечению вкусов")
        }
        if mix.sectionTitle != nil {
            return L10n.text("Официальная подборка VK")
        }
        return L10n.text("Подобрано алгоритмами VK")
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
            Text(L10n.text("Пока доступен только персональный микс"))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(
                L10n.text(
                    "VK ещё не подготовил тематические подборки для вашего аккаунта — загляните позже или откройте Селену."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    hubTab = .selena
                } label: {
                    Text(L10n.text("Открыть Селену"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text(L10n.text("Обновить"))
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
            Text(L10n.text("Не удалось загрузить миксы"))
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load(force: true) }
            } label: {
                Text(L10n.text("Обновить"))
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
        .accessibilityLabel(L10n.text("Загружаем рекомендации и миксы"))
    }

    private func actionErrorRow(_ message: String) -> some View {
        Button { actionError = nil } label: {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private func resumePinned(_ pin: PinnedMixSnapshot) {
        let mix = pin.mix
        if mix.id == MusicMix.common.id {
            hubTab = .selena
            selenaTracks = pin.tracks
            selenaRationale = MixRationaleBuilder.build(
                mixTracks: pin.tracks,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
        } else {
            hubTab = .vk
            applyVKSelection(
                resolvedVKMix(from: pin) ?? mix,
                tracks: pin.tracks
            )
        }
        player.resumePinned(pin) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixTracksContinuation(
                    mix,
                    accessToken: token
                )
            }
        }
        // `resumePinned` replays through `play`, which resets the ordering,
        // so re-apply the pinned mode afterwards. Previously this only
        // restored the picker's appearance while the queue stayed unranked.
        if let saved = MixRadioMode(rawValue: pin.radioMode ?? ""),
           saved != .balanced {
            player.rerankUpcomingMix(
                mode: saved,
                historyArtists: Set(
                    history.entries.prefix(40).map(\.track.artist)
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

    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil,
              force || mixes.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            mixes = try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixes(accessToken: token)
            }
            loadErrorMessage = nil
            if force || selenaTracks.isEmpty {
                await loadSelenaTracks()
            }
            ensureVKSelection(forceReload: force)
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    private func loadSelenaTracks() async {
        do {
            let bootstrap = try await environment.withAuthorizedToken {
                token in
                try await environment.musicService.mixTracksBootstrap(
                    .common,
                    accessToken: token
                )
            }
            selenaTracks = bootstrap
            MixBootstrapPrefetch.artwork(for: bootstrap)
            selenaRationale = MixRationaleBuilder.build(
                mixTracks: bootstrap,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
            trackLoadTask?.cancel()
            trackLoadTask = Task {
                do {
                    let more = try await environment.withAuthorizedToken {
                        token in
                        try await environment.musicService
                            .mixTracksContinuation(
                                .common,
                                accessToken: token
                            )
                    }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        selenaTracks = mergeTracks(selenaTracks, more)
                    }
                } catch {}
            }
        } catch is CancellationError {
            return
        } catch {
            // Catalog may still show shelves; Selena tracks retry on refresh.
        }
    }

    private func ensureVKSelection(forceReload: Bool = false) {
        guard !orderedVKMixes.isEmpty else {
            selectedVKMix = nil
            vkTracks = []
            vkRationale = .empty
            return
        }
        let preferred =
            selectedVKMix.flatMap { current in
                orderedVKMixes.first { $0.id == current.id }
            }
            ?? pinnedMixStore.pin.flatMap { pin in
                orderedVKMixes.first { $0.id == pin.mixID }
            }
            ?? orderedVKMixes.first
        guard let mix = preferred else { return }
        if selectedVKMix?.id != mix.id {
            applyVKSelection(mix, tracks: vkTrackCache[mix.id])
        } else if forceReload || vkTracks.isEmpty {
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
        tracks: [Track]?
    ) {
        selectedVKMix = mix
        if let tracks, !tracks.isEmpty {
            vkTracks = tracks
            let rationale = vkRationaleCache[mix.id]
                ?? MixRationaleBuilder.build(
                    mixTracks: tracks,
                    history: history.entries,
                    recommendations: homeCatalog.recommendations
                )
            vkRationale = rationale
            vkTrackCache[mix.id] = tracks
            vkRationaleCache[mix.id] = rationale
        } else {
            vkTracks = []
            vkRationale = .empty
            loadVKTracks(mix)
        }
    }

    private func loadVKTracks(_ mix: MusicMix) {
        trackLoadTask?.cancel()
        loadingMixID = mix.id
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
                let more = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksContinuation(
                        mix,
                        accessToken: token
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    storeTracks(
                        mergeTracks(tracks(for: mix), more),
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

    private func start(
        _ mix: MusicMix,
        applying mode: MixRadioMode? = nil
    ) {
        guard sessionStore.accessToken != nil else { return }
        if mix.id != MusicMix.common.id, selectedVKMix?.id != mix.id {
            selectVKMix(mix)
        }
        let loaded = tracks(for: mix)
        if let first = loaded.first {
            playTrack(first, queue: loaded, mix: mix, applying: mode)
            fillQueueInBackground(mix)
            return
        }
        loadingMixID = mix.id
        queueFillTask?.cancel()
        Task {
            defer { loadingMixID = nil }
            do {
                let bootstrap = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksBootstrap(
                        mix,
                        accessToken: token
                    )
                }
                guard let first = bootstrap.first else { return }
                MixBootstrapPrefetch.artwork(for: bootstrap)
                storeTracks(bootstrap, for: mix)
                playTrack(first, queue: bootstrap, mix: mix, applying: mode)
                fillQueueInBackground(mix)
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
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
            continuation: {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.mixTracksContinuation(
                        mix,
                        accessToken: token
                    )
                }
            },
            source: .mix(title: mix.title)
        )
        // `play` resets the ordering for the fresh queue; re-apply when the
        // user got here by choosing a mode rather than pressing play.
        if let mode, mode != .balanced {
            applyRadio(mode, mix: mix)
        }
    }

    private func fillQueueInBackground(_ mix: MusicMix) {
        queueFillTask?.cancel()
        queueFillTask = Task {
            do {
                let more = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksContinuation(
                        mix,
                        accessToken: token
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    player.appendToQueue(more)
                    storeTracks(
                        mergeTracks(tracks(for: mix), more),
                        for: mix
                    )
                }
            } catch {}
        }
    }

    private func storeTracks(_ tracks: [Track], for mix: MusicMix) {
        let cleaned = environment.filteredMixTracks(tracks)
        let rationale = MixRationaleBuilder.build(
            mixTracks: cleaned,
            history: history.entries,
            recommendations: homeCatalog.recommendations
        )
        if mix.id == MusicMix.common.id {
            selenaTracks = cleaned
            selenaRationale = rationale
            return
        }
        vkTrackCache[mix.id] = cleaned
        vkRationaleCache[mix.id] = rationale
        if selectedVKMix?.id == mix.id {
            vkTracks = cleaned
            vkRationale = rationale
        }
    }

    private func pin(mix: MusicMix, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
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
        // Radio describes the live queue. When this mix is not playing yet,
        // picking a mode used to change nothing at all — start the mix in
        // that ordering instead of leaving an inert control.
        guard case .mix = player.queueSource,
              !player.queue.isEmpty else {
            start(mix, applying: mode)
            return
        }
        let artists = Set(history.entries.prefix(40).map(\.track.artist))
        player.rerankUpcomingMix(mode: mode, historyArtists: artists)
        let current = tracks(for: mix)
        let queue = current.isEmpty ? player.queue : current
        guard let seed = player.currentTrack ?? queue.first else { return }
        storeTracks(
            MixQueueRanker.rerank(
                queue: queue,
                currentIndex: player.currentIndex ?? 0,
                seed: seed,
                mode: mode,
                historyArtists: artists
            ),
            for: mix
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
}

private struct MixHubMetrics {
    let width: CGFloat

    var horizontalPadding: CGFloat { width <= 350 ? 14 : 16 }
    var cardSpacing: CGFloat { width <= 350 ? 10 : 12 }
    var heroHeight: CGFloat { width <= 350 ? 176 : 200 }
    var contentWidth: CGFloat { max(0, width - horizontalPadding * 2) }
    var cardWidth: CGFloat {
        max(136, contentWidth * 0.38)
    }
    var cardHeight: CGFloat { cardWidth }
    var trackWidth: CGFloat {
        min(max(width * 0.36, 114), 148)
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
