import SwiftUI

/// Dedicated Mix tab hub: personal hero + official VK mix shelves.
struct MixesHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mixes: [MusicMix] = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var selectedMix: MusicMix?
    @State private var loadingMixID: String?
    @State private var actionError: String?
    @State private var queueFillTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let metrics = MixHubMetrics(width: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        titleHeader
                            .id(MainTabScrollDestination.mix)

                        personalHero(metrics: metrics)

                        if isLoading && mixes.count <= 1 {
                            skeleton(metrics: metrics)
                        } else if let loadErrorMessage,
                                  socialMixes.isEmpty,
                                  officialShelves.isEmpty,
                                  algorithmicMixes.isEmpty {
                            loadErrorState(loadErrorMessage)
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
                            if socialMixes.isEmpty,
                               officialShelves.isEmpty,
                               algorithmicMixes.isEmpty {
                                emptyMixesState
                            }
                        }

                        if let actionError {
                            actionErrorRow(actionError)
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .onReceive(scrollCoordinator.$request) { request in
                guard request?.destination == .mix else { return }
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
        }
        .background(ThemeBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(
            isPresented: Binding(
                get: { selectedMix != nil },
                set: { if !$0 { selectedMix = nil } }
            )
        ) {
            if let selectedMix {
                MixView(mix: selectedMix)
            }
        }
        .refreshable {
            await load(force: true)
        }
        .task(id: sessionStore.accessToken) {
            await load()
        }
        .onDisappear {
            queueFillTask?.cancel()
        }
    }

    // Loaded independently from HomeCatalogStore: mixes used to be a Home
    // section sharing that store's coarse, 15-minute-stale cache, which
    // left this tab silently stuck showing just the personal mix whenever
    // Home's own fetch happened to come back thin — with no error and no
    // way to retry short of waiting out the cache. This tab now owns its
    // own fetch/retry, same as MixView already does per-mix.
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
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    private var socialMixes: [MusicMix] {
        mixes.filter { $0.id != MusicMix.common.id && $0.isSocial }
    }

    /// Official catalog sections (mood / genre / VK mixes page), excluding
    /// social cards which already have their own shelf.
    private var officialShelves: [(title: String, mixes: [MusicMix])] {
        let candidates = mixes.filter {
            $0.id != MusicMix.common.id
                && !$0.isSocial
                && ($0.sectionTitle?.isEmpty == false)
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
        let shelvedIDs = Set(officialShelves.flatMap(\.mixes).map(\.id))
        return mixes.filter {
            $0.id != MusicMix.common.id
                && !$0.isSocial
                && !shelvedIDs.contains($0.id)
        }
    }

    private var personalMix: MusicMix {
        mixes.first(where: { $0.id == MusicMix.common.id }) ?? .common
    }

    private var titleHeader: some View {
        Text(L10n.text("Микс"))
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func personalHero(metrics: MixHubMetrics) -> some View {
        let mix = personalMix
        return Button { start(mix) } label: {
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
                    Text(L10n.text("Персональный микс"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .textCase(.uppercase)
                        .tracking(0.55)
                    Text(mix.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(heroSubtitle)
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
            Button { selectedMix = mix } label: {
                Label("Открыть микс", systemImage: "list.bullet")
            }
        }
    }

    private var heroSubtitle: String {
        if let name = sessionStore.profile?.firstName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("Селена подготовила подборку для %@", name)
        }
        return L10n.text("Селена подготовила подборку специально для вас")
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
                Button { selectedMix = mix } label: {
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

                Button { start(mix) } label: {
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

            Button { selectedMix = mix } label: {
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
            Button { start(mix) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
            Button { selectedMix = mix } label: {
                Label("Открыть микс", systemImage: "list.bullet")
            }
        }
    }

    private func cardSubtitle(for mix: MusicMix, social: Bool) -> String {
        if social, let percent = mix.matchPercent {
            return L10n.format("совпадение с вашим вкусом · %d%%", percent)
        }
        if social {
            return L10n.text("совпадение с вашим вкусом")
        }
        return mix.subtitle
    }

    private var emptyMixesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L10n.text("Пока доступен только персональный микс"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(
                L10n.text(
                    "VK ещё не подготовил тематические подборки для вашего аккаунта — загляните позже."
                )
            )
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
            .padding(.top, 6)
            .disabled(isLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.horizontal, 24)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L10n.text("Не удалось загрузить миксы"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
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
            .padding(.top, 6)
            .disabled(isLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.horizontal, 24)
    }

    private func skeleton(metrics: MixHubMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(
                cornerRadius: PremiumLayout.cardRadius,
                style: .continuous
            )
            .fill(.primary.opacity(0.08))
            .frame(height: metrics.heroHeight)
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
        Button {
            actionError = nil
        } label: {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start(_ mix: MusicMix) {
        guard sessionStore.accessToken != nil else { return }
        loadingMixID = mix.id
        queueFillTask?.cancel()
        Task {
            defer { loadingMixID = nil }
            do {
                // First page only — start playback immediately.
                let bootstrap = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksBootstrap(
                        mix,
                        accessToken: token
                    )
                }
                guard let first = bootstrap.first else { return }
                player.play(
                    first,
                    in: bootstrap,
                    continuation: {
                        try await environment.withAuthorizedToken { token in
                            try await environment.musicService
                                .mixTracksContinuation(
                                    mix,
                                    accessToken: token
                                )
                        }
                    },
                    source: .mix(title: mix.title)
                )
                // Quiet background fill — one more batch, no 4+4 spam.
                queueFillTask = Task {
                    do {
                        let more = try await environment.withAuthorizedToken {
                            token in
                            try await environment.musicService
                                .mixTracksContinuation(
                                    mix,
                                    accessToken: token
                                )
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            player.appendToQueue(more)
                        }
                    } catch {
                        // Playback already started; fill is best-effort.
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
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
