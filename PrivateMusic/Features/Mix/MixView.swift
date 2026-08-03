import SwiftUI

struct MixView: View {
    let mix: MusicMix

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @State private var mixes: [MusicMix] = []
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var loadingMixID: String?
    @State private var errorMessage: String?
    @State private var sharingTrack: Track?

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
        .task(id: sessionStore.accessToken) {
            await load(force: true)
        }
        .refreshable { await load(force: true) }
    }

    private var hero: some View {
        Button { start(mix) } label: {
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
            Button { start(mix) } label: {
                Label("Воспроизвести микс", systemImage: "play.fill")
            }
        }
        .disabled(loadingMixID != nil)
    }

    private var mixShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ваши VK Миксы")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(mixes.filter { $0.id != mix.id }) { mix in
                        Button { start(mix) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    if let artwork = mix.artworkURL {
                                        AsyncArtwork(url: artwork, size: 166)
                                    } else {
                                        LinearGradient(
                                            colors: [.purple, .blue],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        Image(systemName: "waveform")
                                            .font(.system(size: 44, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                }
                                .frame(width: 166, height: 166)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius:
                                            14,
                                        style: .continuous
                                    )
                                )
                                Text(mix.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(mix.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 166, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                        .contextMenu {
                            Button { start(mix) } label: {
                                Label("Воспроизвести микс", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
        }
    }

    private var recommendationShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Для вас")
                .font(.title2.weight(.bold))
            Text("Подобрано по вашим прослушиваниям VK")
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Продолжить поток")
                .font(.title2.weight(.bold))
            VStack(spacing: 0) {
                ForEach(Array(tracks.dropFirst(12).prefix(12).enumerated()),
                        id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        queue: tracks,
                        source: .mix(title: mix.title)
                    )
                        .padding(.vertical, 7)
                    if index < min(max(tracks.count - 12, 0), 12) - 1 {
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
                play(
                    first,
                    queue: queue,
                    mix: mix,
                    source: .mix(title: mix.title)
                )
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
                    try await environment.musicService.mixTracks(
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
        do {
            mixes = try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixes(
                    accessToken: token
                )
            }
        } catch is CancellationError {
            return
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            tracks = try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixTracks(
                    mix,
                    accessToken: token
                )
            }
        } catch is CancellationError {
            return
        } catch {
            failures.append(error.localizedDescription)
        }
        errorMessage = failures.first
    }
}
