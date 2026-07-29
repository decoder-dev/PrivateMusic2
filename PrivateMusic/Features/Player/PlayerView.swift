import SwiftUI
import UIKit
import AVKit

struct PlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var artworkDrag: CGSize = .zero
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingArtist = false
    @State private var showingPlaylists = false
    @State private var showingSettings = false
    @State private var showingActionPanel = false
    @State private var shareFileURL: URL?
    @State private var shareCleanupURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var isPreparingShare = false
    @State private var isInLibrary = false
    @State private var isUpdatingLibrary = false
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
                    if showingActionPanel {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingActionPanel = false
                            }
                        actionPanel(track)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topTrailing
                            )
                            .padding(.top, 56)
                            .padding(.trailing, 22)
                            .transition(
                                .opacity.combined(
                                    with: .scale(
                                        scale: 0.96,
                                        anchor: .topTrailing
                                    )
                                )
                            )
                    }
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
        .dynamicTypeSize(...DynamicTypeSize.large)
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
            ),
            onDismiss: cleanupSharedFile
        ) {
            if let shareFileURL {
                TrackShareSheet(fileURL: shareFileURL)
            }
        }
        .onChange(of: player.currentTrack?.id) { _ in
            shareTask?.cancel()
            shareTask = nil
            updateLibraryState()
            isUpdatingLibrary = false
            showingActionPanel = false
        }
        .task(id: player.currentTrack?.id) {
            updateLibraryState()
        }
        .onChange(of: libraryStore.signatures) { _ in
            updateLibraryState()
        }
        .onDisappear {
            shareTask?.cancel()
            shareTask = nil
            if shareFileURL == nil {
                cleanupSharedFile()
            }
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
                        .scaleEffect(1.28)
                        .blur(radius: 78)
                        .saturation(1.12)
                } placeholder: {
                    Color.clear
                }
            }
            Color.black.opacity(0.56)
            LinearGradient(
                colors: [
                    .black.opacity(0.18),
                    .black.opacity(0.42),
                    .black.opacity(0.92)
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
        let compact = size.height < 740
        let spacious = size.height >= 820
        let horizontalPadding: CGFloat = compact ? 20 : 22
        let contentWidth = max(size.width - horizontalPadding * 2, 0)
        let artworkSize = min(
            contentWidth,
            size.height * (compact ? 0.36 : 0.38)
        )

        return VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 2) {
                    Text("СЕЙЧАС ИГРАЕТ")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(queuePosition)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.38))
                }
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                            .overlay {
                                Circle().stroke(
                                    .white.opacity(0.08),
                                    lineWidth: 0.5
                                )
                            }
                    }
                    .buttonStyle(PlayerControlStyle())
                    Spacer()
                    HStack(spacing: 8) {
                        AirPlayRoutePicker()
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                            .overlay {
                                Circle().stroke(
                                    .white.opacity(0.08),
                                    lineWidth: 0.5
                                )
                            }
                        actionMenuButton
                    }
                }
            }
            .frame(height: 40)
            .padding(.top, compact ? 6 : 10)

            AsyncArtwork(url: track.artworkURL, size: artworkSize)
                .id(track.id)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity.combined(with: .scale(scale: 1.02))
                    )
                )
                .animation(
                    reduceMotion
                        ? nil
                        : .spring(response: 0.42, dampingFraction: 0.86),
                    value: track.id
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
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
                .padding(
                    .top,
                    compact ? 12 : (spacious ? 34 : 28)
                )

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(
                            .system(
                                size: compact ? 21 : 23,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Button {
                        showingArtist = true
                    } label: {
                        Text(track.artist)
                            .font(.system(size: compact ? 14 : 15))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.58))
                    if let album = track.albumTitle, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.36))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                Button {
                    toggleLibrary(track)
                } label: {
                    Image(
                        systemName: isInLibrary ? "heart.fill" : "heart"
                    )
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(
                        isInLibrary ? .white : .white.opacity(0.72)
                    )
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(PlayerControlStyle())
                .disabled(isUpdatingLibrary)
                .accessibilityLabel(
                    isInLibrary
                        ? "Удалить из медиатеки"
                        : "Добавить в медиатеку"
                )
            }
            .padding(
                .top,
                compact ? 10 : (spacious ? 21 : 16)
            )

            VStack(spacing: 3) {
                CompactPlayerSlider(
                    value: Binding(
                        get: { player.elapsedTime },
                        set: { player.seek(to: $0) }
                    ),
                    range: 0...max(player.duration, 1)
                )
                .frame(height: 20)
                .accessibilityLabel("Позиция воспроизведения")
                HStack {
                    Text(player.elapsedTime.formattedDuration)
                    Spacer()
                    Text("-\(remainingTime.formattedDuration)")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.52))
            }
            .padding(
                .top,
                compact ? 8 : (spacious ? 16 : 12)
            )

            primaryControls
                .padding(
                    .top,
                    compact ? 5 : (spacious ? 14 : 9)
                )

            quickActions(track)
                .padding(
                    .top,
                    compact ? 9 : (spacious ? 28 : 16)
                )

            Spacer(minLength: compact ? 6 : 12)
        }
        .frame(
            width: contentWidth,
            height: size.height,
            alignment: .top
        )
        .padding(.horizontal, horizontalPadding)
        .foregroundStyle(.white)
    }

    private var actionMenuButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                showingActionPanel.toggle()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 0.5)
                }
        }
        .buttonStyle(PlayerControlStyle())
        .accessibilityLabel("Действия с треком")
    }

    private func actionPanel(_ track: Track) -> some View {
        VStack(spacing: 0) {
            panelAction(
                isInLibrary ? "Удалить из медиатеки" : "В медиатеку",
                systemImage: isInLibrary ? "heart.slash" : "heart"
            ) {
                showingActionPanel = false
                toggleLibrary(track)
            }
            panelAction("Исполнитель", systemImage: "person.wave.2") {
                showingActionPanel = false
                showingArtist = true
            }
            panelAction(
                "Добавить в плейлист",
                systemImage: "rectangle.stack.badge.plus"
            ) {
                showingActionPanel = false
                showingPlaylists = true
            }
            panelAction("Поделиться", systemImage: "square.and.arrow.up") {
                showingActionPanel = false
                startShare(track)
            }
            .disabled(isPreparingShare)
            Divider().overlay(.white.opacity(0.08))
            Toggle(isOn: $settings.equalizerEnabled) {
                Label("Эквалайзер", systemImage: "waveform")
            }
            .tint(.white)
            .padding(.horizontal, 16)
            .frame(height: 48)
            panelAction(
                "Настройки звука",
                systemImage: "slider.horizontal.3"
            ) {
                showingActionPanel = false
                showingSettings = true
            }
            Text("Качество: автоматически VK")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 258)
        .background(
            Color(white: 0.105).opacity(0.99),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
    }

    private func panelAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerControlStyle())
    }

    private var primaryControls: some View {
        HStack(spacing: 0) {
            secondaryButton(
                "shuffle",
                active: player.shuffleEnabled,
                label: "Перемешать"
            ) {
                Haptics.selection()
                player.toggleShuffle()
            }
            Spacer()
            Button {
                Haptics.trackChange()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            Spacer()
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 29, weight: .bold))
                    .frame(width: 60, height: 60)
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            Spacer()
            Button {
                Haptics.trackChange()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 48, height: 52)
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
        .buttonStyle(PlayerControlStyle())
    }

    private func quickActions(_ track: Track) -> some View {
        HStack(spacing: 0) {
            quickAction("quote.bubble", title: "Текст") {
                showingLyrics = true
            }
            quickAction("list.bullet", title: "Очередь") {
                showingQueue = true
            }
            quickAction(
                "rectangle.stack.badge.plus",
                title: "Плейлист"
            ) {
                showingPlaylists = true
            }
            quickAction(
                isPreparingShare
                    ? "arrow.triangle.2.circlepath"
                    : "square.and.arrow.up",
                title: "Экспорт"
            ) {
                startShare(track)
            }
        }
    }

    private func quickAction(
        _ image: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: image)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 34)
                    .background(.white.opacity(0.07), in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.66))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(PlayerControlStyle())
    }

    private func secondaryButton(
        _ image: String,
        active: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 19, weight: .semibold))
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

    private var queuePosition: String {
        guard let currentIndex = player.currentIndex,
              !player.queue.isEmpty else {
            return "PRIVATE MUSIC"
        }
        return "\(currentIndex + 1) ИЗ \(player.queue.count)"
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

    private func prepareShare(_ track: Track) async {
        guard let token = sessionStore.accessToken else {
            player.errorMessage = "Войдите во VK, чтобы экспортировать песню."
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let refreshed = try await environment.musicService.refreshedTrack(
                track,
                accessToken: token
            )
            guard !Task.isCancelled,
                  player.currentTrack?.id == track.id else {
                return
            }
            cleanupSharedFile()
            let fileURL = try await shareService.prepareFile(
                for: refreshed,
                userAgent: sessionStore.userAgent
            )
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            shareCleanupURL = fileURL
            shareFileURL = fileURL
            Haptics.selection()
        } catch is CancellationError {
            return
        } catch {
            player.errorMessage =
                "Не удалось экспортировать песню. Обновите сессию VK "
                + "или попробуйте ещё раз."
        }
    }

    private func startShare(_ track: Track) {
        guard shareTask == nil else { return }
        shareTask = Task {
            await prepareShare(track)
            shareTask = nil
        }
    }

    private func cleanupSharedFile() {
        guard let url = shareCleanupURL else { return }
        try? FileManager.default.removeItem(at: url)
        shareCleanupURL = nil
    }

    private func toggleLibrary(_ track: Track) {
        guard !isUpdatingLibrary,
              let token = sessionStore.accessToken else {
            return
        }
        let removing = isInLibrary
        isUpdatingLibrary = true
        Task {
            defer { isUpdatingLibrary = false }
            do {
                if removing {
                    let stored = libraryStore.storedTrack(for: track) ?? track
                    try await environment.musicService.removeFromLibrary(
                        stored,
                        accessToken: token
                    )
                    libraryStore.markRemoved(track)
                    libraryStore.markRemoved(stored)
                    MusicLibraryEvents.postRemoved(stored)
                    if player.currentTrack?.id == track.id {
                        isInLibrary = false
                    }
                } else {
                    let added = try await environment.musicService.addToLibrary(
                        track,
                        accessToken: token
                    )
                    libraryStore.markAdded(source: track, stored: added)
                    MusicLibraryEvents.postAdded(added)
                    if player.currentTrack?.id == track.id {
                        isInLibrary = true
                    }
                }
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                let action = removing ? "удалить" : "добавить"
                player.errorMessage = "Не удалось \(action) трек: "
                    + error.localizedDescription
            }
        }
    }

    private func updateLibraryState() {
        guard let track = player.currentTrack else {
            isInLibrary = false
            return
        }
        isInLibrary = libraryStore.contains(track)
            || track.ownerID == sessionStore.session?.userID
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(
        _ picker: AVRoutePickerView,
        context: Context
    ) {
        picker.tintColor = .white
        picker.activeTintColor = .white
    }
}

private struct CompactPlayerSlider: UIViewRepresentable {
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.isContinuous = true
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.18)
        slider.setThumbImage(Self.thumbImage, for: .normal)
        slider.setThumbImage(Self.highlightedThumbImage, for: .highlighted)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(max(range.upperBound, range.lowerBound + 1))
        guard !slider.isTracking else { return }
        let safeValue = value.isFinite ? value : range.lowerBound
        slider.setValue(
            Float(min(max(safeValue, range.lowerBound), range.upperBound)),
            animated: false
        )
    }

    private static let thumbImage = makeThumb(diameter: 12)
    private static let highlightedThumbImage = makeThumb(diameter: 15)

    private static func makeThumb(diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.28).cgColor
            )
            UIColor.white.setFill()
            UIBezierPath(
                ovalIn: CGRect(origin: .zero, size: size).insetBy(
                    dx: 0.5,
                    dy: 0.5
                )
            )
            .fill()
        }
    }

    final class Coordinator: NSObject {
        var parent: CompactPlayerSlider

        init(parent: CompactPlayerSlider) {
            self.parent = parent
        }

        @objc
        func valueChanged(_ slider: UISlider) {
            parent.value = TimeInterval(slider.value)
        }
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
