import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var artworkDrag: CGSize = .zero
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingArtist = false
    @State private var showingPlaylists = false
    @State private var shareFileURL: URL?
    @State private var isPreparingShare = false
    @State private var isInLibrary = false
    @State private var showingSettings = false
    private let shareService = TrackShareService()
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let artworkURL = player.currentTrack?.artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 70)
                                .saturation(1.15)
                                .opacity(settings.theme == .dark ? 0.34 : 0.2)
                        }
                    }
                    .ignoresSafeArea()
                }
                LinearGradient(
                    colors: [
                        settings.theme.colors.last
                            ?? Color(uiColor: .secondarySystemBackground),
                        settings.theme.colors[0]
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(settings.theme == .dark ? 0.82 : 0.88)
                .ignoresSafeArea()

                if let track = player.currentTrack {
                    ScrollView {
                        VStack(spacing: 24) {
                            AsyncArtwork(url: track.artworkURL, size: 280)
                                .shadow(
                                    color: .black.opacity(0.18),
                                    radius: 24,
                                    y: 12
                                )
                                .offset(
                                    x: reduceMotion
                                        ? 0
                                        : artworkDrag.width * 0.22,
                                    y: reduceMotion
                                        ? 0
                                        : artworkDrag.height * 0.12
                                )
                                .rotationEffect(
                                    .degrees(
                                        reduceMotion
                                            ? 0
                                            : artworkDrag.width / 45
                                    )
                                )
                                .gesture(artworkGesture)
                                .accessibilityHint(
                                    "Смахните в стороны для смены трека, "
                                        + "вверх для очереди"
                                )

                            VStack(spacing: 7) {
                                Text(track.title)
                                    .font(.title2.bold())
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Text(track.artist)
                                    .foregroundStyle(.secondary)
                                if let album = track.albumTitle,
                                   !album.isEmpty {
                                    Text(album)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                if player.isBuffering {
                                    Label(
                                        "Буферизация",
                                        systemImage: "waveform"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 10) {
                                playerAction(
                                    isInLibrary ? "heart.fill" : "heart",
                                    label: "В медиатеку"
                                ) {
                                    addToLibrary(track)
                                }
                                playerAction(
                                    "person.wave.2",
                                    label: "Исполнитель"
                                ) {
                                    showingArtist = true
                                }
                                playerAction(
                                    "quote.bubble",
                                    label: "Текст"
                                ) {
                                    showingLyrics = true
                                }
                                playerAction(
                                    "rectangle.stack.badge.plus",
                                    label: "Добавить в плейлист"
                                ) {
                                    showingPlaylists = true
                                }
                                Button {
                                    Task { await prepareShare(track) }
                                } label: {
                                    if isPreparingShare {
                                        ProgressView()
                                            .frame(width: 42, height: 42)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                            .frame(width: 42, height: 42)
                                            .background(
                                                .thinMaterial,
                                                in: Circle()
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isPreparingShare)
                                .accessibilityLabel("Поделиться")
                            }

                            VStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { player.elapsedTime },
                                        set: { player.seek(to: $0) }
                                    ),
                                    in: 0...max(player.duration, 1)
                                )
                                HStack {
                                    Text(player.elapsedTime.formattedDuration)
                                    Spacer()
                                    Text(player.duration.formattedDuration)
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            playbackControls
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                } else {
                    EmptyStateView(
                        title: "Плеер",
                        systemImage: "play.circle",
                        description: "Выберите трек в медиатеке, "
                            + "рекомендациях или поиске."
                    )
                    .padding()
                }
            }
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Закрыть") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showingQueue = true
                        } label: {
                            Label("Очередь", systemImage: "list.bullet")
                        }
                        Toggle(
                            "Эквалайзер",
                            isOn: $settings.equalizerEnabled
                        )
                        Button {
                            showingSettings = true
                        } label: {
                            Label(
                                "Настройки звука",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        Text("Качество: автоматически VK")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showingQueue) {
            QueueView()
        }
        .sheet(isPresented: $showingLyrics) {
            if let track = player.currentTrack {
                LyricsView(track: track)
            }
        }
        .sheet(isPresented: $showingArtist) {
            if let track = player.currentTrack {
                ArtistView(artist: track.artist)
            }
        }
        .sheet(isPresented: $showingPlaylists) {
            if let track = player.currentTrack {
                AddToPlaylistView(track: track)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(
            isPresented: Binding(
                get: { shareFileURL != nil },
                set: {
                    if !$0 {
                        shareFileURL = nil
                    }
                }
            )
        ) {
            if let shareFileURL {
                TrackShareSheet(fileURL: shareFileURL)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button {
                Haptics.selection()
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(
                        player.shuffleEnabled
                            ? settings.theme.accent
                            : Color.primary
                    )
            }
            Button {
                Haptics.trackChange()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                Image(
                    systemName: player.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: 68))
            }
            Button {
                Haptics.trackChange()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            Button {
                Haptics.selection()
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(
                        player.repeatMode == .off
                            ? Color.primary
                            : settings.theme.accent
                    )
            }
        }
        .font(.title2)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .adaptiveGlass(in: Capsule(), interactive: true)
    }

    private var artworkGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($artworkDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(horizontal) > abs(vertical) {
                    if horizontal < -58 {
                        Haptics.trackChange()
                        player.next()
                    } else if horizontal > 58 {
                        Haptics.trackChange()
                        player.previous()
                    }
                } else if vertical < -62 {
                    Haptics.open()
                    showingQueue = true
                } else if vertical > 78, showsCloseButton {
                    dismiss()
                }
            }
    }

    private func playerAction(
        _ image: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func prepareShare(_ track: Track) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            shareFileURL = try await shareService.prepareFile(for: track)
        } catch {
            player.errorMessage = "Не удалось подготовить файл: "
                + error.localizedDescription
        }
    }

    private func addToLibrary(_ track: Track) {
        guard let token = sessionStore.accessToken else { return }
        Task {
            do {
                try await environment.musicService.addToLibrary(
                    track,
                    accessToken: token
                )
                isInLibrary = true
                Haptics.selection()
            } catch {
                player.errorMessage = "Не удалось добавить трек: "
                    + error.localizedDescription
            }
        }
    }
}
