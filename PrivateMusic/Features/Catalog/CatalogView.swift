import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @State private var recommendations: [Track] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                welcomeHeader

                if isLoading
                    && recommendations.isEmpty
                    && playlists.isEmpty {
                    loadingCard
                } else if recommendations.isEmpty && playlists.isEmpty {
                    unavailableCard
                } else {
                    if let errorMessage {
                        warningBanner(errorMessage)
                    }
                    if !recommendations.isEmpty {
                        featuredSection
                        recommendationsSection
                    }
                    if !playlists.isEmpty {
                        playlistsSection
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(ThemeBackground())
        .navigationTitle("Главная")
        .refreshable { await load(force: true) }
        .task { await load() }
    }

    private var welcomeHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(sessionStore.profile?.firstName ?? "Слушатель")
                    .font(.largeTitle.bold())
            }
            Spacer()
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 50)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.primary.opacity(0.08))
                }
        }
        .padding(.top, 4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Доброе утро"
        case 12..<18: return "Добрый день"
        case 18..<23: return "Добрый вечер"
        default: return "Доброй ночи"
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Быстрый старт",
                subtitle: "Нажмите на обложку, чтобы включить"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(recommendations.prefix(12)) { track in
                        Button {
                            player.play(track, in: recommendations)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    AsyncArtwork(
                                        url: track.artworkURL,
                                        size: 148
                                    )
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(
                                            settings.theme.accent,
                                            in: Circle()
                                        )
                                        .shadow(
                                            color: .black.opacity(0.2),
                                            radius: 8,
                                            y: 3
                                        )
                                        .padding(8)
                                }
                                Text(track.title)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 148, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Для вас",
                subtitle: "Персональная подборка VK"
            )

            VStack(spacing: 0) {
                ForEach(
                    Array(0..<min(recommendations.count, 30)),
                    id: \.self
                ) { index in
                    TrackRow(
                        track: recommendations[index],
                        queue: recommendations
                    )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    if index < min(recommendations.count, 30) - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Ваши плейлисты",
                subtitle: "\(playlists.count) доступно"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists.prefix(12)) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                AsyncArtwork(
                                    url: playlist.artworkURL,
                                    size: 138
                                )
                                Text(playlist.title)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(playlist.count) треков")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 138, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private func sectionHeader(
        _ title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 14) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("Собираем музыку")
                    .font(.headline)
                Text("Рекомендации и плейлисты появятся здесь")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 22))
    }

    private var unavailableCard: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                title: "Главная недоступна",
                systemImage: "wifi.exclamationmark",
                description: errorMessage ?? "VK не вернул данные."
            )
            .frame(height: 260)
            Button("Повторить") {
                Task { await load(force: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.bottom, 20)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Повторить загрузку")
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken,
              force || recommendations.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        var failures: [String] = []

        do {
            recommendations = try await environment.musicService.recommendations(
                accessToken: token
            )
        } catch {
            failures.append(error.localizedDescription)
        }

        do {
            let playlistPage = try await environment.musicService.playlists(
                accessToken: token,
                offset: 0,
                count: 30
            )
            playlists = playlistPage.items
        } catch {
            failures.append(error.localizedDescription)
        }

        errorMessage = failures.first
    }
}
