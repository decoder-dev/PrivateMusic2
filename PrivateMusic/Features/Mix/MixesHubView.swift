import SwiftUI

/// Single Mix tab screen: Selena vs VK as segments — no nested detail pushes.
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
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @EnvironmentObject private var history: ListeningHistoryStore
    @EnvironmentObject private var pinnedMixStore: PinnedMixStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hubTab: HubTab = .selena
    @State private var mixes: [MusicMix] = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var loadingMixID: String?
    @State private var actionError: String?
    @State private var queueFillTask: Task<Void, Never>?
    @State private var trackLoadTask: Task<Void, Never>?

    @State private var selenaTracks: [Track] = []
    @State private var selenaRationale: MixRationale = .empty
    @State private var focusedVKMix: MusicMix?
    @State private var focusedVKTracks: [Track] = []
    @State private var focusedVKRationale: MixRationale = .empty
    @State private var radioMode: MixRadioMode = .balanced
    @State private var sharingTrack: Track?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let metrics = MixHubMetrics(width: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
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
            .onChange(of: focusedVKMix?.id) { id in
                guard id != nil else { return }
                scrollHubToTop(proxy: proxy)
            }
        }
        .background(ThemeBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .trackShareSheet(track: $sharingTrack)
        .refreshable { await load(force: true) }
        .task(id: sessionStore.accessToken) { await load() }
        .onChange(of: hubTab) { tab in
            if tab == .selena {
                focusedVKMix = nil
                focusedVKTracks = []
            }
        }
        .onDisappear {
            queueFillTask?.cancel()
            trackLoadTask?.cancel()
        }
    }

    // MARK: - Selena tab

    @ViewBuilder
    private func selenaContent(metrics: MixHubMetrics) -> some View {
        playHero(
            mix: personalMix,
            metrics: metrics,
            subtitle: selenaHeroSubtitle
        )

        if !selenaRationale.isEmpty {
            rationaleBlock(
                selenaRationale,
                title: L10n.text("Почему Селена")
            )
        }

        controlsPanel(
            mix: personalMix,
            tracks: selenaTracks
        )

        if isLoading && selenaTracks.isEmpty {
            skeleton(metrics: metrics)
        } else if let loadErrorMessage, selenaTracks.isEmpty {
            loadErrorState(loadErrorMessage)
        } else if !selenaTracks.isEmpty {
            tracksBlock(
                mix: personalMix,
                tracks: selenaTracks,
                metrics: metrics
            )
        }
    }

    // MARK: - VK tab

    @ViewBuilder
    private func vkContent(metrics: MixHubMetrics) -> some View {
        if let focused = focusedVKMix {
            focusedVKPanel(mix: focused, metrics: metrics)
        } else if isLoading && vkMixes.isEmpty {
            skeleton(metrics: metrics)
        } else if let loadErrorMessage, vkMixes.isEmpty {
            loadErrorState(loadErrorMessage)
        } else if vkMixes.isEmpty {
            emptyMixesState
        } else {
            if !socialMixes.isEmpty {
                mixShelf(
                    title: "Слушайте друг друга",
                    mixes: socialMixes,
                    metrics: metrics,
                    showsMatchBadge: true
                )
            }
            ForEach(officialShelves, id: \.title) { shelf in
                mixShelf(
                    title: shelf.title,
                    mixes: shelf.mixes,
                    metrics: metrics,
                    showsMatchBadge: false
                )
            }
            if !algorithmicMixes.isEmpty {
                mixShelf(
                    title: "Собрано алгоритмами",
                    mixes: algorithmicMixes,
                    metrics: metrics,
                    showsMatchBadge: false
                )
            }
        }
    }

    @ViewBuilder
    private func focusedVKPanel(
        mix: MusicMix,
        metrics: MixHubMetrics
    ) -> some View {
        Button {
            focusedVKMix = nil
            focusedVKTracks = []
            focusedVKRationale = .empty
            radioMode = .balanced
        } label: {
            Label(L10n.text("Все миксы"), systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)

        playHero(
            mix: mix,
            metrics: metrics,
            subtitle: cardSubtitle(for: mix, social: mix.isSocial)
        )

        if !focusedVKRationale.isEmpty {
            rationaleBlock(
                focusedVKRationale,
                title: L10n.text("Почему этот микс")
            )
        }

        controlsPanel(mix: mix, tracks: focusedVKTracks)

        if loadingMixID == mix.id && focusedVKTracks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if !focusedVKTracks.isEmpty {
            tracksBlock(
                mix: mix,
                tracks: focusedVKTracks,
                metrics: metrics
            )
        }
    }

    // MARK: - Shared blocks

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
                            .lineLimit(1)
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
                .padding(10)
                .background(
                    RoundedRectangle(
                        cornerRadius: 14,
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
        }
    }

    private func playHero(
        mix: MusicMix,
        metrics: MixHubMetrics,
        subtitle: String
    ) -> some View {
        Button { start(mix) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.38, blue: 0.98),
                        Color(red: 0.42, green: 0.18, blue: 0.92),
                        Color(red: 0.55, green: 0.22, blue: 0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: 6) {
                    Spacer(minLength: 0)
                    if let curator = mix.curator, curator.isUsable {
                        Text(curator.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .textCase(.uppercase)
                            .tracking(0.55)
                    } else if mix.id == MusicMix.common.id {
                        Text(L10n.text("Персональный микс"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .textCase(.uppercase)
                            .tracking(0.55)
                    }
                    Text(mix.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .padding(.trailing, 72)

                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.indigo)
                    .frame(width: 52, height: 52)
                    .background(.white, in: Circle())
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topTrailing
                    )
                    .padding(18)

                if loadingMixID == mix.id {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.22))
                }
            }
            .foregroundStyle(.white)
            .frame(height: metrics.heroHeight)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PremiumLayout.cardRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(PremiumPressStyle())
        .disabled(loadingMixID != nil)
        .accessibilityLabel(L10n.text("Воспроизвести микс"))
        .contextMenu {
            Button { start(mix) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
            Button {
                pin(mix: mix, tracks: tracks(for: mix))
            } label: {
                Label("Слушать позже", systemImage: "bookmark")
            }
            .disabled(tracks(for: mix).isEmpty)
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
                    "Переставляет уже загруженную очередь без новых запросов"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker(L10n.text("Режим"), selection: $radioMode) {
                ForEach(MixRadioMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: radioMode) { mode in
                applyRadio(mode, mix: mix)
            }

            HStack(spacing: 10) {
                Button { start(mix) } label: {
                    Label(
                        L10n.text("Слушать"),
                        systemImage: "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
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
                }
                .buttonStyle(.bordered)
                .disabled(tracks.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    private func tracksBlock(
        mix: MusicMix,
        tracks: [Track],
        metrics: MixHubMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Для вас"))
                    .font(.title2.weight(.bold))
                Text(L10n.text("Подобрано по вашим прослушиваниям VK"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(tracks.prefix(12)) { track in
                            trackCard(track, mix: mix, queue: tracks)
                        }
                    }
                }
            }

            let list = Array(tracks.dropFirst(12).prefix(36))
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Продолжить поток"))
                        .font(.title2.weight(.bold))
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
                }
            }
        }
    }

    private func trackCard(
        _ track: Track,
        mix: MusicMix,
        queue: [Track]
    ) -> some View {
        Button {
            playTrack(track, queue: queue, mix: mix)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncArtwork(url: track.artworkURL, size: 148)
                        .overlay(alignment: .topTrailing) {
                            LikedTrackBadge(
                                track: track,
                                style: .artwork
                            )
                            .padding(8)
                        }
                    Group {
                        if player.currentTrack?.id == track.id {
                            PlaybackIndicatorView(
                                isPlaying: player.isPlaying,
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
            .frame(width: 148, alignment: .leading)
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
            Button { sharingTrack = track } label: {
                Label(
                    "Поделиться аудиофайлом",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private func mixShelf(
        title: String,
        mixes: [MusicMix],
        metrics: MixHubMetrics,
        showsMatchBadge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(title))
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(mixes) { mix in
                        mixCard(
                            mix,
                            metrics: metrics,
                            showsMatchBadge: showsMatchBadge
                        )
                    }
                }
            }
        }
    }

    private func mixCard(
        _ mix: MusicMix,
        metrics: MixHubMetrics,
        showsMatchBadge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    focusVKMix(mix)
                } label: {
                    ZStack(alignment: .topLeading) {
                        MixArtworkView(
                            mix: mix,
                            tracks: homeCatalog.recommendations,
                            size: metrics.cardWidth,
                            height: metrics.cardHeight,
                            cornerRadius: 16
                        )
                        if showsMatchBadge, let percent = mix.matchPercent {
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

                Button {
                    startFocused(mix)
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
            }

            Button {
                focusVKMix(mix)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mix.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(cardSubtitle(for: mix, social: showsMatchBadge))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(width: metrics.cardWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { startFocused(mix) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
            Button { focusVKMix(mix) } label: {
                Label("Открыть здесь", systemImage: "list.bullet")
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

    private var socialMixes: [MusicMix] {
        vkMixes.filter(\.isSocial)
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

    private var selenaHeroSubtitle: String {
        if let name = sessionStore.profile?.firstName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("Селена подготовила подборку для %@", name)
        }
        return L10n.text("Селена подготовила подборку специально для вас")
    }

    private func cardSubtitle(for mix: MusicMix, social: Bool) -> String {
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
        if social, let percent = mix.matchPercent {
            return L10n.format("совпадение с вашим вкусом · %d%%", percent)
        }
        if social {
            return L10n.text("совпадение с вашим вкусом")
        }
        return mix.subtitle
    }

    private func tracks(for mix: MusicMix) -> [Track] {
        mix.id == MusicMix.common.id ? selenaTracks : focusedVKTracks
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
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text(L10n.text("Обновить"))
                        .font(.subheadline.weight(.semibold))
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(0.08))
                .frame(height: 44)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.cardSpacing) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(
                            cornerRadius: 16,
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
            radioMode = MixRadioMode(rawValue: pin.radioMode ?? "") ?? .balanced
        } else {
            hubTab = .vk
            focusedVKMix = mix
            focusedVKTracks = pin.tracks
            focusedVKRationale = MixRationaleBuilder.build(
                mixTracks: pin.tracks,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
            radioMode = MixRadioMode(rawValue: pin.radioMode ?? "") ?? .balanced
        }
        player.resumePinned(pin) {
            try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixTracksContinuation(
                    mix,
                    accessToken: token
                )
            }
        }
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

    private func focusVKMix(_ mix: MusicMix) {
        focusedVKMix = mix
        focusedVKTracks = []
        focusedVKRationale = .empty
        radioMode = .balanced
        trackLoadTask?.cancel()
        loadingMixID = mix.id
        trackLoadTask = Task {
            defer { loadingMixID = nil }
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
                    focusedVKTracks = bootstrap
                    MixBootstrapPrefetch.artwork(for: bootstrap)
                    focusedVKRationale = MixRationaleBuilder.build(
                        mixTracks: bootstrap,
                        history: history.entries,
                        recommendations: homeCatalog.recommendations
                    )
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
                    focusedVKTracks = mergeTracks(focusedVKTracks, more)
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

    private func startFocused(_ mix: MusicMix) {
        hubTab = .vk
        trackLoadTask?.cancel()
        if focusedVKMix?.id != mix.id {
            focusedVKMix = mix
            focusedVKTracks = []
            focusedVKRationale = .empty
            radioMode = .balanced
        }
        start(mix)
    }

    private func start(_ mix: MusicMix) {
        guard sessionStore.accessToken != nil else { return }
        let loaded = tracks(for: mix)
        if let first = loaded.first {
            playTrack(first, queue: loaded, mix: mix)
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
                playTrack(first, queue: bootstrap, mix: mix)
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
        mix: MusicMix
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
                    storeTracks(mergeTracks(tracks(for: mix), more), for: mix)
                }
            } catch {}
        }
    }

    private func storeTracks(_ tracks: [Track], for mix: MusicMix) {
        if mix.id == MusicMix.common.id {
            selenaTracks = tracks
            selenaRationale = MixRationaleBuilder.build(
                mixTracks: tracks,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
        } else if focusedVKMix?.id == mix.id {
            focusedVKTracks = tracks
            focusedVKRationale = MixRationaleBuilder.build(
                mixTracks: tracks,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
        }
    }

    private func pin(mix: MusicMix, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pinnedMixStore.pin(
            mix: mix,
            tracks: tracks,
            currentIndex: player.currentIndex ?? 0,
            elapsed: player.elapsedTime,
            radioMode: radioMode
        )
    }

    private func applyRadio(_ mode: MixRadioMode, mix: MusicMix) {
        guard case .mix = player.queueSource,
              !player.queue.isEmpty else {
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
    }

    private func mergeTracks(_ lhs: [Track], _ rhs: [Track]) -> [Track] {
        var known = Set(lhs.map(\.id))
        var result = lhs
        for track in rhs where known.insert(track.id).inserted {
            result.append(track)
        }
        return Array(result.prefix(MixTrackRequestPolicy.queueLimit))
    }
}

private struct MixHubMetrics {
    let width: CGFloat

    var horizontalPadding: CGFloat { 16 }
    var cardSpacing: CGFloat { 12 }
    var heroHeight: CGFloat { 188 }
    var cardWidth: CGFloat {
        max(148, (width - horizontalPadding * 2 - cardSpacing) * 0.42)
    }
    var cardHeight: CGFloat { cardWidth }
}
