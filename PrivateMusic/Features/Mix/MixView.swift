import SwiftUI

struct MixView: View {
    let mix: MusicMix

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var history: ListeningHistoryStore
    @EnvironmentObject private var homeCatalog: HomeCatalogStore
    @EnvironmentObject private var pinnedMixStore: PinnedMixStore
    @State private var mixes: [MusicMix] = []
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var loadingMixID: String?
    @State private var errorMessage: String?
    @State private var sharingTrack: Track?
    @State private var selectedMix: MusicMix?
    @State private var queueFillTask: Task<Void, Never>?
    @State private var rationale: MixRationale = .empty
    @State private var radioMode: MixRadioMode = .balanced

    init(mix: MusicMix = .common) {
        self.mix = mix
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if isLoading && tracks.isEmpty {
                    skeleton
                } else {
                    hero
                    if !rationale.isEmpty { rationaleSection }
                    radioControls
                    pinRow
                    if mixes.count > 1 { mixShelf }
                    if !tracks.isEmpty {
                        recommendationShelf
                        algorithmSection
                    }
                    if let errorMessage {
                        retry(errorMessage)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .background(ThemeBackground())
        .navigationTitle(mix.title)
        .trackShareSheet(track: $sharingTrack)
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
        .task(id: "\(sessionStore.accessToken ?? "")-\(mix.id)") {
            await load(force: true)
        }
        .refreshable { await load(force: true) }
        .onDisappear { queueFillTask?.cancel() }
    }

    private var hero: some View {
        Button { start(mix, preferLoaded: true) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.42, blue: 1),
                        Color(red: 0.48, green: 0.12, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    Text(mix.title)
                        .font(.title2.weight(.heavy))
                    Text(mix.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(22)
                Image(systemName: "play.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.indigo)
                    .frame(width: 58, height: 58)
                    .background(.white, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topTrailing)
                    .padding(18)
                if loadingMixID == mix.id {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.22))
                }
            }
            .foregroundStyle(.white)
            .frame(height: 230)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PremiumLayout.cardRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button { start(mix, preferLoaded: true) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
        }
        .disabled(loadingMixID != nil)
    }

    private var rationaleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Почему Селена"))
                .font(.title3.weight(.bold))
            ForEach(rationale.lines, id: \.self) { line in
                Text("· \(line)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var radioControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Радио микса"))
                .font(.title3.weight(.bold))
            Text(L10n.text("Переставляет уже загруженную очередь без новых запросов"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(L10n.text("Режим"), selection: $radioMode) {
                ForEach(MixRadioMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: radioMode) { mode in
                applyRadio(mode)
            }
        }
    }

    private var pinRow: some View {
        Button {
            guard !tracks.isEmpty else { return }
            pinnedMixStore.pin(
                mix: mix,
                tracks: tracks,
                currentIndex: player.currentIndex ?? 0,
                elapsed: player.elapsedTime,
                radioMode: radioMode
            )
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

    private var mixShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Ваши VK Миксы"))
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(mixes.filter { $0.id != mix.id }) { other in
                        Button { selectedMix = other } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MixArtworkView(
                                    mix: other,
                                    tracks: tracks,
                                    size: 166,
                                    cornerRadius: 14
                                )
                                Text(other.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(other.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 166, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            Button { start(other, preferLoaded: false) } label: {
                                Label(
                                    "Воспроизвести микс",
                                    systemImage: "play.fill"
                                )
                            }
                            Button { selectedMix = other } label: {
                                Label("Открыть микс", systemImage: "list.bullet")
                            }
                        }
                    }
                }
            }
        }
    }

    private var recommendationShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Для вас"))
                .font(.title2.weight(.bold))
            Text(L10n.text("Подобрано по вашим прослушиваниям VK"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(tracks.prefix(12)) { track in
                        Button {
                            play(
                                track,
                                queue: tracks,
                                mix: mix,
                                source: .mix(title: mix.title)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    AsyncArtwork(
                                        url: track.artworkURL,
                                        size: 166
                                    )
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
                                        .frame(width: 42, height: 42)
                                        .background(.white, in: Circle())
                                        .padding(8)
                                }
                                Text(track.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 166, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            Button { player.playNext(track) } label: {
                                Label(
                                    "Играть следующим",
                                    systemImage: "text.badge.plus"
                                )
                            }
                            Button {
                                play(
                                    track,
                                    queue: tracks,
                                    mix: mix,
                                    source: .mix(title: mix.title)
                                )
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
                }
            }
        }
    }

    private var algorithmSection: some View {
        let list = Array(tracks.dropFirst(12).prefix(36))
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Продолжить поток"))
                .font(.title2.weight(.bold))
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) {
                    index,
                    track in
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

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 26) {
            RoundedRectangle(
                cornerRadius: PremiumLayout.cardRadius,
                style: .continuous
            )
                .fill(.primary.opacity(0.08))
                .frame(height: 230)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                            .fill(.primary.opacity(0.08))
                            .frame(width: 166, height: 205)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func retry(_ message: String) -> some View {
        Button {
            Task { await load(force: true) }
        } label: {
            Label(message, systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start(_ mix: MusicMix, preferLoaded: Bool) {
        guard sessionStore.accessToken != nil else { return }
        if preferLoaded,
           mix.id == self.mix.id,
           let first = tracks.first {
            play(
                first,
                queue: tracks,
                mix: mix,
                source: .mix(title: mix.title)
            )
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
                if mix.id == self.mix.id {
                    tracks = bootstrap
                    rationale = MixRationaleBuilder.build(
                        mixTracks: bootstrap,
                        history: history.entries,
                        recommendations: homeCatalog.recommendations
                    )
                }
                play(
                    first,
                    queue: bootstrap,
                    mix: mix,
                    source: .mix(title: mix.title)
                )
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
                            if mix.id == self.mix.id {
                                tracks = mergeTracks(tracks, more)
                            }
                        }
                    } catch {
                        // Playback already started.
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func play(
        _ track: Track,
        queue: [Track],
        mix: MusicMix = .common,
        source: QueueSource? = nil
    ) {
        guard sessionStore.accessToken != nil else { return }
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
            source: source
        )
    }

    private func load(force: Bool = false) async {
        guard sessionStore.accessToken != nil,
              force || tracks.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        var failures: [String] = []

        async let mixesResult: Result<[MusicMix], Error> = {
            do {
                let value = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixes(accessToken: token)
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }()
        async let tracksResult: Result<[Track], Error> = {
            do {
                let value = try await environment.withAuthorizedToken {
                    token in
                    try await environment.musicService.mixTracksBootstrap(
                        mix,
                        accessToken: token
                    )
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }()

        switch await mixesResult {
        case let .success(value):
            mixes = value
        case let .failure(error):
            if error is CancellationError { return }
            failures.append(error.localizedDescription)
        }

        switch await tracksResult {
        case let .success(value):
            tracks = value
            MixBootstrapPrefetch.artwork(for: value)
            rationale = MixRationaleBuilder.build(
                mixTracks: value,
                history: history.entries,
                recommendations: homeCatalog.recommendations
            )
        case let .failure(error):
            if error is CancellationError { return }
            failures.append(error.localizedDescription)
        }

        errorMessage = failures.first

        // Background fill of the remaining mix pages for the detail list.
        if !tracks.isEmpty {
            queueFillTask?.cancel()
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
                        tracks = mergeTracks(tracks, more)
                    }
                } catch {
                    // Detail UI already has the bootstrap page.
                }
            }
        }
    }

    private func applyRadio(_ mode: MixRadioMode) {
        guard case .mix = player.queueSource,
              !player.queue.isEmpty else {
            return
        }
        let historyArtists = Set(history.entries.prefix(40).map(\.track.artist))
        player.rerankUpcomingMix(
            mode: mode,
            historyArtists: historyArtists
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
