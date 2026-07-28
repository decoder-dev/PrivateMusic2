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
    @State private var showingSettings = false
    @State private var shareFileURL: URL?
    @State private var isPreparingShare = false
    @State private var isInLibrary = false
    @State private var isAddingToLibrary = false
    private let shareService = TrackShareService()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                artworkBackground

                if let track = player.currentTrack {
                    playerContent(
                        track,
                        size: proxy.size
                    )
                } else {
                    EmptyStateView(
                        title: "Плеер",
                        systemImage: "play.circle",
                        description: "Выберите трек в медиатеке или миксе."
                    )
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .clipped()
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .ignoresSafeArea(edges: .bottom)
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
                set: { if !$0 { shareFileURL = nil } }
            )
        ) {
            if let shareFileURL {
                TrackShareSheet(fileURL: shareFileURL)
            }
        }
        .onChange(of: player.currentTrack?.id) { _ in
            updateLibraryState()
            isAddingToLibrary = false
        }
        .task(id: player.currentTrack?.id) {
            updateLibraryState()
        }
    }

    private var artworkBackground: some View {
        ZStack {
            Color.black
            if let artworkURL = player.currentTrack?.artworkURL {
                CachedRemoteImage(url: artworkURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.35)
                        .blur(radius: 72)
                        .saturation(1.25)
                } placeholder: {
                    Color.clear
                }
            }
            Color.black.opacity(0.48)
            LinearGradient(
                colors: [
                    .black.opacity(0.12),
                    .black.opacity(0.5),
                    .black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func playerContent(
        _ track: Track,
        size: CGSize
    ) -> some View {
        let compact = size.height < 730
        let horizontalPadding: CGFloat = compact ? 22 : 26
        let contentWidth = max(size.width - horizontalPadding * 2, 0)
        let artworkSize = min(
            contentWidth,
            size.height * (compact ? 0.39 : 0.43)
        )

        return VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 46, height: 5)
                .padding(.top, compact ? 8 : 14)
                .accessibilityLabel("Смахните вниз, чтобы закрыть")

            Spacer(minLength: compact ? 14 : 32)

            AsyncArtwork(url: track.artworkURL, size: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
                .offset(
                    x: reduceMotion ? 0 : artworkDrag.width * 0.16,
                    y: reduceMotion ? 0 : artworkDrag.height * 0.08
                )
                .rotationEffect(
                    .degrees(reduceMotion ? 0 : artworkDrag.width / 65)
                )
                .gesture(artworkGesture)
                .accessibilityHint(
                    "Свайп в стороны меняет трек, вверх открывает очередь, "
                        + "вниз закрывает плеер"
                )

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                    if let album = track.albumTitle, !album.isEmpty {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                actionMenu(track)
            }
            .padding(.top, compact ? 18 : 28)

            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { player.elapsedTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1)
                )
                .tint(.white)
                HStack {
                    Text(player.elapsedTime.formattedDuration)
                    Spacer()
                    Text("-\(remainingTime.formattedDuration)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.top, compact ? 20 : 32)

            Spacer(minLength: compact ? 16 : 28)
            primaryControls
            Spacer(minLength: compact ? 18 : 34)
            secondaryControls
            Spacer(minLength: compact ? 18 : 30)
        }
        .frame(
            width: contentWidth,
            height: size.height,
            alignment: .top
        )
        .padding(.horizontal, horizontalPadding)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
    }

    private func actionMenu(_ track: Track) -> some View {
        Menu {
            Button { addToLibrary(track) } label: {
                Label(
                    isInLibrary ? "Добавлено в медиатеку" : "В медиатеку",
                    systemImage: isInLibrary ? "heart.fill" : "heart"
                )
            }
            .disabled(isInLibrary || isAddingToLibrary)
            Button { showingArtist = true } label: {
                Label("Исполнитель", systemImage: "person.wave.2")
            }
            Button { showingPlaylists = true } label: {
                Label(
                    "Добавить в плейлист",
                    systemImage: "rectangle.stack.badge.plus"
                )
            }
            Button {
                Task { await prepareShare(track) }
            } label: {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingShare)
            Divider()
            Toggle("Эквалайзер", isOn: $settings.equalizerEnabled)
            Button { showingSettings = true } label: {
                Label(
                    "Настройки звука",
                    systemImage: "slider.horizontal.3"
                )
            }
            Text("Качество: автоматически VK")
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                if isPreparingShare {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(.black)
                }
            }
        }
        .accessibilityLabel("Действия с треком")
    }

    private var primaryControls: some View {
        HStack {
            Button {
                Haptics.trackChange()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .frame(width: 82, height: 74)
            }
            Spacer()
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 62, weight: .bold))
                    .frame(width: 92, height: 82)
            }
            Spacer()
            Button {
                Haptics.trackChange()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .frame(width: 82, height: 74)
            }
        }
        .buttonStyle(PlayerControlStyle())
    }

    private var secondaryControls: some View {
        HStack {
            secondaryButton(
                "shuffle",
                active: player.shuffleEnabled,
                label: "Перемешать"
            ) {
                Haptics.selection()
                player.toggleShuffle()
            }
            Spacer()
            secondaryButton(
                "quote.bubble",
                active: false,
                label: "Текст"
            ) {
                showingLyrics = true
            }
            Spacer()
            secondaryButton(
                "list.bullet",
                active: false,
                label: "Очередь"
            ) {
                showingQueue = true
            }
            Spacer()
            secondaryButton(
                player.repeatMode.systemImage,
                active: player.repeatMode != .off,
                label: "Повтор"
            ) {
                Haptics.selection()
                player.cycleRepeatMode()
            }
        }
        .padding(.horizontal, 14)
    }

    private func secondaryButton(
        _ image: String,
        active: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(
                    active ? Color.white : Color.white.opacity(0.58)
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var remainingTime: TimeInterval {
        max(player.duration - player.elapsedTime, 0)
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
                } else if vertical < -60 {
                    showingQueue = true
                } else if vertical > 72 {
                    dismiss()
                }
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                guard value.translation.height > 110,
                      abs(value.translation.width)
                        < value.translation.height else {
                    return
                }
                dismiss()
            }
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
        guard !isAddingToLibrary,
              let token = sessionStore.accessToken else {
            return
        }
        isAddingToLibrary = true
        Task {
            defer { isAddingToLibrary = false }
            do {
                let added = try await environment.musicService.addToLibrary(
                    track,
                    accessToken: token
                )
                guard player.currentTrack?.id == track.id else { return }
                isInLibrary = true
                MusicLibraryEvents.postAdded(added)
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                player.errorMessage = "Не удалось добавить трек: "
                    + error.localizedDescription
            }
        }
    }

    private func updateLibraryState() {
        guard let track = player.currentTrack else {
            isInLibrary = false
            return
        }
        isInLibrary = track.ownerID == sessionStore.session?.userID
    }
}

private struct PlayerControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.2, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}
