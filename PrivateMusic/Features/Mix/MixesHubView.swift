import SwiftUI

/// Dedicated Mix tab hub: personal hero + social shelf + algorithmic mixes.
struct MixesHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var scrollCoordinator: MainTabScrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedMix: MusicMix?
    @State private var loadingMixID: String?
    @State private var actionError: String?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let metrics = MixHubMetrics(width: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        titleHeader
                            .id(MainTabScrollDestination.mix)

                        personalHero(metrics: metrics)

                        if !socialMixes.isEmpty {
                            mixShelf(
                                title: "Слушайте друг друга",
                                mixes: socialMixes,
                                metrics: metrics,
                                showsMatchBadge: true
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

                        if homeCatalog.isRefreshing
                            && socialMixes.isEmpty
                            && algorithmicMixes.isEmpty {
                            skeleton(metrics: metrics)
                        }

                        if let actionError {
                            retryRow(actionError)
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
            await environment.refreshHomeCatalog(force: true)
        }
        .task(id: sessionStore.accessToken) {
            if homeCatalog.mixes.isEmpty {
                await environment.refreshHomeCatalog()
            }
        }
    }

    private var mixes: [MusicMix] { homeCatalog.mixes }

    private var socialMixes: [MusicMix] {
        mixes.filter { $0.id != MusicMix.common.id && $0.isSocial }
    }

    private var algorithmicMixes: [MusicMix] {
        mixes.filter { $0.id != MusicMix.common.id && !$0.isSocial }
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

                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
                    Text(heroTitle)
                        .font(.title2.weight(.bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.86)
                    Text(L10n.text("Музыкальные рекомендации для вас"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
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

    private var heroTitle: String {
        if let name = sessionStore.profile?.firstName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("%@ подготовил(а) кое-что для вас", name)
        }
        return L10n.text("Персональный микс для вас")
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

    private func retryRow(_ message: String) -> some View {
        Button {
            Task { await environment.refreshHomeCatalog(force: true) }
        } label: {
            Label(message, systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start(_ mix: MusicMix) {
        guard sessionStore.accessToken != nil else { return }
        loadingMixID = mix.id
        Task {
            defer { loadingMixID = nil }
            do {
                let queue = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracks(
                        mix,
                        accessToken: token
                    )
                }
                guard let first = queue.first else { return }
                player.play(
                    first,
                    in: queue,
                    continuation: {
                        try await environment.withAuthorizedToken { token in
                            try await environment.musicService.mixTracks(
                                mix,
                                accessToken: token
                            )
                        }
                    },
                    source: .mix(title: mix.title)
                )
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
    var heroHeight: CGFloat { 168 }
    var cardWidth: CGFloat {
        max(148, (width - horizontalPadding * 2 - cardSpacing) * 0.42)
    }
    var cardHeight: CGFloat { cardWidth }
}
