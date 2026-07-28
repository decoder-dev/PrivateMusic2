import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: ListeningHistoryStore
    @State private var recommendations: [Track] = []
    @State private var mixes: [MusicMix] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var loadingMixID: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                welcomeHeader

                if !history.entries.isEmpty {
                    recentlyPlayedSection
                }
                if isLoading && contentIsEmpty {
                    catalogSkeleton
                } else {
                    if !mixes.isEmpty { mixesSection }
                    if !recommendations.isEmpty {
                        recommendationsSection
                        trackListSection
                    }
                    if !playlists.isEmpty { playlistsSection }
                    if contentIsEmpty { unavailableView }
                    if let errorMessage, !contentIsEmpty {
                        retryRow(errorMessage)
                    }
                }
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.bottom, 110)
        }
        .background(ThemeBackground())
        .navigationTitle("Главная")
        .refreshable { await load(force: true) }
        .task { await load() }
    }

    private var contentIsEmpty: Bool {
        recommendations.isEmpty && mixes.isEmpty && playlists.isEmpty
    }

    private var welcomeHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(sessionStore.profile?.firstName ?? "Слушатель")
                    .font(.largeTitle.weight(.heavy))
                    .lineLimit(1)
            }
            Spacer()
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 48)
                .clipShape(Circle())
                .overlay { Circle().stroke(.primary.opacity(0.12)) }
        }
        .padding(.top, 6)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: "Доброе утро"
        case 12..<18: "Добрый день"
        case 18..<23: "Добрый вечер"
        default: "Доброй ночи"
        }
    }

    private var mixesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeader(
                "Миксы VK",
                subtitle: "Персональный поток под ваш вкус"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(mixes) { mix in
                        Button { start(mix) } label: {
                            ZStack(alignment: .bottomLeading) {
                                AsyncArtwork(url: mix.artworkURL, size: 186)
                                    .overlay {
                                        LinearGradient(
                                            colors: [.clear, .black.opacity(0.82)],
                                            startPoint: .center,
                                            endPoint: .bottom
                                        )
                                    }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mix.title)
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(mix.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(2)
                                }
                                .padding(14)
                                if loadingMixID == mix.id {
                                    ProgressView()
                                        .tint(.white)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(.black.opacity(0.28))
                                }
                            }
                            .frame(width: 186, height: 186)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(PremiumPressStyle())
                        .disabled(loadingMixID != nil)
                    }
                }
            }
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeader(
                "Для вас",
                subtitle: "Рекомендации на основе прослушиваний VK"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(recommendations.prefix(14)) { track in
                        Button {
                            player.play(track, in: recommendations)
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                ZStack(alignment: .bottomTrailing) {
                                    AsyncArtwork(url: track.artworkURL, size: 154)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(
                                            settings.theme.buttonForeground
                                        )
                                        .frame(width: 40, height: 40)
                                        .background(
                                            settings.theme.accent,
                                            in: Circle()
                                        )
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
                            .frame(width: 154, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                    }
                }
            }
        }
    }

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeader(
                "Недавно слушали",
                subtitle: "История сохраняется только на этом устройстве"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(history.entries.prefix(12)) { entry in
                        Button {
                            let tracks = history.entries.map(\.track)
                            player.play(entry.track, in: tracks)
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                AsyncArtwork(
                                    url: entry.track.artworkURL,
                                    size: 132
                                )
                                Text(entry.track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(entry.track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                    }
                }
            }
        }
    }

    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeader("Ещё для вас")
            VStack(spacing: 0) {
                ForEach(Array(recommendations.prefix(20).enumerated()), id: \.element.id) {
                    index, track in
                    TrackRow(track: track, queue: recommendations)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    if index < min(recommendations.count, 20) - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .premiumCard()
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeader(
                "Ваши плейлисты",
                subtitle: "\(playlists.count) в медиатеке"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists.prefix(16)) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                AsyncArtwork(url: playlist.artworkURL, size: 146)
                                Text(playlist.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(playlist.count) треков")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 146, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                    }
                }
            }
        }
    }

    private var catalogSkeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<2, id: \.self) { section in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.11))
                        .frame(width: section == 0 ? 130 : 190, height: 22)
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 9) {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(.primary.opacity(0.09))
                                    .frame(width: 146, height: 146)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.primary.opacity(0.09))
                                    .frame(width: 112, height: 12)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.primary.opacity(0.06))
                                    .frame(width: 78, height: 10)
                            }
                        }
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Загружаем рекомендации и миксы")
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 40, weight: .medium))
            Text("Музыка пока недоступна")
                .font(.title3.bold())
            Text(errorMessage ?? "VK не вернул рекомендации и миксы.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Обновить") { Task { await load(force: true) } }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func retryRow(_ message: String) -> some View {
        Button { Task { await load(force: true) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(14)
            .premiumCard(interactive: true)
        }
        .buttonStyle(PremiumPressStyle())
    }

    private func start(_ mix: MusicMix) {
        guard let token = sessionStore.accessToken else { return }
        loadingMixID = mix.id
        Task {
            defer { loadingMixID = nil }
            do {
                let tracks = try await environment.musicService.mixTracks(
                    mix,
                    accessToken: token
                )
                guard let first = tracks.first else { return }
                player.play(first, in: tracks) {
                    try await environment.musicService.mixTracks(
                        mix,
                        accessToken: token
                    )
                }
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Не удалось запустить «\(mix.title)»: "
                    + error.localizedDescription
            }
        }
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken,
              force || contentIsEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        var failures: [String] = []

        do {
            recommendations = try await environment.musicService
                .recommendations(accessToken: token)
        } catch is CancellationError {
            return
        } catch {
            failures.append("Рекомендации: \(error.localizedDescription)")
        }

        do {
            mixes = try await environment.musicService.mixes(
                accessToken: token
            )
        } catch is CancellationError {
            return
        } catch {
            failures.append("Миксы: \(error.localizedDescription)")
        }

        do {
            playlists = try await environment.musicService.playlists(
                accessToken: token,
                offset: 0,
                count: 30
            ).items
        } catch is CancellationError {
            return
        } catch {
            failures.append("Плейлисты: \(error.localizedDescription)")
        }

        errorMessage = failures.first
    }
}
