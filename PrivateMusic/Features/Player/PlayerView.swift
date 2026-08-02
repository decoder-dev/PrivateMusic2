import SwiftUI
import UIKit
import AVKit

struct PlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @GestureState private var artworkDrag: CGSize = .zero
    @State private var presentedSheet: PlayerSheet?
    @State private var deferredPlayerAction: DeferredPlayerAction?
    @State private var isInLibrary = false
    @State private var isUpdatingLibrary = false
    @State private var scrubPosition: TimeInterval?
    @State private var showCopiedToast = false
    @State private var sharingTrack: Track?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                artworkBackground

                if let track = player.currentTrack {
                    playerContent(
                        track,
                        size: proxy.size,
                        safeInsets: proxy.safeAreaInsets
                    )
                } else {
                    EmptyStateView(
                        title: "Плеер",
                        systemImage: "play.circle",
                        description: "Выберите трек в медиатеке или миксе."
                    )
                    .foregroundStyle(playerForeground)
                    .padding()
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(playerBackground.ignoresSafeArea())
        .preferredColorScheme(settings.theme.colorScheme)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(
            item: $presentedSheet,
            onDismiss: handleSheetDismissal
        ) { sheet in
            presentedSheetContent(sheet)
        }
        .trackShareSheet(track: $sharingTrack)
        .onChange(of: player.currentTrack?.id) { _ in
            deferredPlayerAction = nil
            scrubPosition = nil
            updateLibraryState()
            isUpdatingLibrary = false
            if isActionSheetPresented {
                presentedSheet = nil
            }
        }
        .task(id: player.currentTrack?.id) {
            updateLibraryState()
        }
        .onChange(of: libraryStore.signatures) { _ in
            updateLibraryState()
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text(L10n.text("Ссылка скопирована"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 40)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCopiedToast)
    }

    private var artworkBackground: some View {
        ZStack {
            playerBackground
            if let artworkURL = player.currentTrack?.artworkURL {
                CachedRemoteImage(
                    url: artworkURL,
                    maxPixelSize: 384
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.28)
                        .blur(radius: 78)
                        .saturation(1.12)
                        .opacity(settings.theme == .light ? 0.18 : 1)
                } placeholder: {
                    Color.clear
                }
            }
            playerBackground.opacity(settings.theme == .light ? 0.72 : 0.56)
            LinearGradient(
                colors: backgroundGradient,
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func playerContent(
        _ track: Track,
        size: CGSize,
        safeInsets: EdgeInsets
    ) -> some View {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: size,
            safeBottom: safeInsets.bottom,
            safeLeading: safeInsets.leading,
            safeTrailing: safeInsets.trailing,
            usesAccessibilityText: dynamicTypeSize.isAccessibilitySize,
            hasAlbum: track.albumTitle?.isEmpty == false
        )

        Group {
            if metrics.requiresAccessibilityScrolling(
                containerHeight: size.height
            ) {
                ScrollView(.vertical) {
                    landscapePlayerContent(track, metrics: metrics)
                        .frame(minHeight: metrics.minimumContentHeight)
                }
                .scrollIndicators(.hidden)
            } else if metrics.mode == .landscape {
                landscapePlayerContent(track, metrics: metrics)
            } else {
                portraitPlayerContent(track, metrics: metrics)
            }
        }
        .frame(
            width: metrics.contentWidth,
            height: size.height
        )
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .foregroundStyle(playerForeground)
    }

    private func portraitPlayerContent(
        _ track: Track,
        metrics: PlayerLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            playerHeader(track)
                .frame(height: metrics.headerHeight)
                .padding(.top, metrics.headerTopPadding)

            Spacer(minLength: metrics.artworkTopSpacing)

            playerArtwork(track, size: metrics.artworkSize)

            Spacer(minLength: metrics.metadataTopSpacing)

            trackMetadata(track)

            Spacer(minLength: metrics.progressTopSpacing)

            progressControls

            Spacer(minLength: metrics.controlsTopSpacing)

            primaryControls
                .frame(height: metrics.primaryControlsHeight)

            Spacer(minLength: metrics.quickActionsTopSpacing)

            quickActions(track)
                .frame(height: metrics.quickActionsHeight)

            Color.clear
                .frame(height: metrics.bottomPadding)
                .accessibilityHidden(true)
        }
    }

    private func landscapePlayerContent(
        _ track: Track,
        metrics: PlayerLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            playerHeader(track)
                .frame(height: metrics.headerHeight)
                .padding(.top, metrics.headerTopPadding)

            Spacer(minLength: metrics.artworkTopSpacing)

            HStack(spacing: metrics.landscapeColumnSpacing) {
                playerArtwork(track, size: metrics.artworkSize)

                VStack(spacing: 0) {
                    trackMetadata(track)

                    Spacer(minLength: metrics.progressTopSpacing)

                    progressControls

                    Spacer(minLength: metrics.controlsTopSpacing)

                    primaryControls
                        .frame(height: metrics.primaryControlsHeight)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: metrics.quickActionsTopSpacing)

            quickActions(track)
                .frame(height: metrics.quickActionsHeight)

            Color.clear
                .frame(height: metrics.bottomPadding)
                .accessibilityHidden(true)
        }
    }

    private func playerHeader(_ track: Track) -> some View {
        AdaptiveGlassContainer(spacing: 8) {
            ZStack {
                VStack(spacing: 2) {
                    Text("СЕЙЧАС ИГРАЕТ")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(playerSecondary)
                    Text(queuePosition)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(playerSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilitySortPriority(1)

                HStack {
                    Button {
                        closePlayer()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .adaptiveGlass(
                                in: Circle(),
                                interactive: true
                            )
                    }
                    .buttonStyle(PlayerControlStyle())
                    .accessibilityLabel(L10n.text("Закрыть плеер"))
                    .accessibilitySortPriority(4)

                    Spacer()

                    HStack(spacing: 8) {
                        AirPlayRoutePicker(
                            tintColor: UIColor(playerForeground)
                        )
                            .frame(width: 44, height: 44)
                            .adaptiveGlass(
                                in: Circle(),
                                interactive: true
                            )
                            .accessibilityLabel(
                                L10n.text(
                                    "Выбрать устройство воспроизведения"
                                )
                            )
                            .accessibilitySortPriority(3)
                        actionMenuButton(track)
                            .accessibilitySortPriority(2)
                    }
                }
            }
        }
    }

    private func playerArtwork(
        _ track: Track,
        size: CGFloat
    ) -> some View {
        AsyncArtwork(url: track.artworkURL, size: size)
            .clipShape(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(playerForeground.opacity(0.08), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
            .offset(
                x: reduceMotion ? 0 : artworkDrag.width * 0.16,
                y: reduceMotion ? 0 : artworkDrag.height * 0.08
            )
            .rotationEffect(
                .degrees(reduceMotion ? 0 : artworkDrag.width / 65)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.3, dampingFraction: 0.82),
                value: artworkDrag == .zero
            )
            .gesture(artworkGesture)
            .accessibilityLabel(
                L10n.format(
                    "Обложка: %@ — %@",
                    track.title,
                    track.artist
                )
            )
            .accessibilityHint(
                L10n.text(
                    "Свайп в стороны меняет трек, вверх открывает очередь, "
                        + "вниз закрывает плеер"
                )
            )
            .accessibilityAction(
                named: L10n.text("Следующий трек")
            ) {
                Haptics.trackChange()
                player.next()
            }
            .accessibilityAction(
                named: L10n.text("Предыдущий трек")
            ) {
                Haptics.trackChange()
                player.previous()
            }
            .accessibilityAction(
                named: L10n.text("Очередь")
            ) {
                present(.queue)
            }
            .accessibilityAction(
                named: L10n.text("Закрыть плеер")
            ) {
                closePlayer()
            }
    }

    private func trackMetadata(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(playerForeground)
                    .lineLimit(1)
                Button {
                    present(.artist(track.artist))
                } label: {
                    Text(track.artist)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(playerSecondary)
                if let album = track.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption2)
                        .foregroundStyle(playerSecondary)
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
                    isInLibrary
                        ? playerForeground
                        : playerForeground.opacity(0.72)
                )
                .frame(width: 44, height: 44)
                .adaptiveGlass(
                    in: Circle(),
                    interactive: true
                )
            }
            .buttonStyle(PlayerControlStyle())
            .disabled(isUpdatingLibrary)
            .accessibilityLabel(
                L10n.text(
                    isInLibrary
                        ? "Удалить из медиатеки"
                        : "Добавить в медиатеку"
                )
            )
            .accessibilityValue(
                L10n.text(
                    isInLibrary
                        ? "Трек добавлен в медиатеку"
                        : "Трек не добавлен в медиатеку"
                )
            )
        }
    }

    private var progressControls: some View {
        VStack(spacing: 3) {
            CompactPlayerSlider(
                value: Binding(
                    get: { displayedElapsedTime },
                    set: { scrubPosition = $0 }
                ),
                range: 0...max(player.duration, 1),
                tintColor: UIColor(playerForeground),
                onEditingBegan: {
                    scrubPosition = player.elapsedTime
                },
                onCommit: commitScrubbing
            )
            .frame(height: 20)
            .accessibilityLabel(
                L10n.text("Позиция воспроизведения")
            )
            .accessibilityValue(
                "\(displayedElapsedTime.formattedDuration) / "
                    + player.duration.formattedDuration
            )

            HStack {
                Text(displayedElapsedTime.formattedDuration)
                Spacer()
                Text("-\(remainingTime.formattedDuration)")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(playerSecondary)
        }
    }

    private func actionMenuButton(_ track: Track) -> some View {
        Button {
            present(.actions(track))
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(playerForeground)
                .frame(width: 44, height: 44)
                .adaptiveGlass(
                    in: Circle(),
                    interactive: true
                )
        }
        .buttonStyle(PlayerControlStyle())
        .accessibilityLabel(L10n.text("Действия с треком"))
    }

    private var primaryControls: some View {
        HStack(spacing: 0) {
            secondaryButton(
                "shuffle",
                active: player.shuffleEnabled,
                label: "Перемешать",
                accessibilityValue: player.shuffleEnabled
                    ? "Перемешивание включено"
                    : "Перемешивание выключено"
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
            .accessibilityLabel(L10n.text("Предыдущий трек"))
            Spacer()
            playPauseButton
            Spacer()
            Button {
                Haptics.trackChange()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            .accessibilityLabel(L10n.text("Следующий трек"))
            Spacer()
            secondaryButton(
                player.repeatMode.systemImage,
                active: player.repeatMode != .off,
                label: "Повтор",
                accessibilityValue: repeatAccessibilityValue
            ) {
                Haptics.selection()
                player.cycleRepeatMode()
            }
        }
        .buttonStyle(PlayerControlStyle())
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if #available(iOS 26.0, *) {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                playPauseLabel
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(playerForeground)
            .foregroundStyle(playerBackground)
            .accessibilityLabel(playPauseAccessibilityLabel)
        } else {
            Button {
                Haptics.selection()
                player.playPause()
            } label: {
                playPauseLabel
                    .background(playerForeground, in: Circle())
                    .foregroundStyle(playerBackground)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(playPauseAccessibilityLabel)
        }
    }

    private var playPauseLabel: some View {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 29, weight: .bold))
            .frame(width: 60, height: 60)
    }

    private var playPauseAccessibilityLabel: String {
        L10n.text(
            player.isPlaying
                ? "Приостановить"
                : "Продолжить воспроизведение"
        )
    }

    private func quickActions(_ track: Track) -> some View {
        AdaptiveGlassContainer(spacing: 14) {
            HStack(spacing: 0) {
                quickAction("quote.bubble", title: "Текст") {
                    present(.lyrics(track))
                }
                quickAction("list.bullet", title: "Очередь") {
                    present(.queue)
                }
                quickAction(
                    "rectangle.stack.badge.plus",
                    title: "Плейлист"
                ) {
                    present(.playlists(track))
                }
                quickAction(
                    "square.and.arrow.up",
                    title: "Поделиться файлом"
                ) {
                    startShare(track)
                }
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
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(in: Circle(), interactive: true)
                Text(L10n.text(title))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(playerForeground.opacity(0.72))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 61)
        }
        .buttonStyle(PlayerControlStyle())
    }

    private func secondaryButton(
        _ image: String,
        active: Bool,
        label: String,
        accessibilityValue: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(
                    active
                        ? playerForeground
                        : playerForeground.opacity(0.58)
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
        .accessibilityValue(L10n.text(accessibilityValue))
    }

    private var repeatAccessibilityValue: String {
        switch player.repeatMode {
        case .off:
            return "Повтор выключен"
        case .all:
            return "Повтор всей очереди"
        case .one:
            return "Повтор одного трека"
        }
    }

    private var remainingTime: TimeInterval {
        max(player.duration - displayedElapsedTime, 0)
    }

    private var playerForeground: Color {
        settings.theme == .light ? .black : .white
    }

    private var playerSecondary: Color {
        playerForeground.opacity(settings.theme == .light ? 0.62 : 0.56)
    }

    private var playerBackground: Color {
        settings.theme == .light ? .white : .black
    }

    private var backgroundGradient: [Color] {
        if settings.theme == .light {
            return [
                .white.opacity(0.28),
                .white.opacity(0.72),
                .white.opacity(0.98),
            ]
        }
        return [
            .black.opacity(0.18),
            .black.opacity(0.42),
            .black.opacity(0.92),
        ]
    }

    private var displayedElapsedTime: TimeInterval {
        scrubPosition ?? player.elapsedTime
    }

    private func commitScrubbing(_ position: TimeInterval) {
        player.seek(to: position)
        scrubPosition = nil
    }

    @ViewBuilder
    private func presentedSheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .queue:
            QueueView()
        case let .lyrics(track):
            LyricsView(track: track)
        case let .artist(artist):
            ArtistView(artist: artist)
        case let .playlists(track):
            AddToPlaylistView(track: track)
        case .settings:
            NavigationStack { SettingsView() }
        case let .actions(track):
            PlayerActionsSheet(
                track: track,
                isInLibrary: isInLibrary,
                offlineState: offlineStore.state(for: track),
                availability: PlayerActionAvailability(
                    hasSession: sessionStore.accessToken != nil,
                    isUpdatingLibrary: isUpdatingLibrary,
                    showsOfflineControls: OfflineDownloadsFeature.showsControls
                        && !environment.isShareSessionActive
                ),
                equalizerEnabled: $settings.equalizerEnabled,
                onDismiss: {
                    presentedSheet = nil
                },
                onLibrary: {
                    presentedSheet = nil
                    toggleLibrary(track)
                },
                onArtist: {
                    deferFromActionSheet(
                        .sheet(.artist(track.artist))
                    )
                },
                onPlaylist: {
                    deferFromActionSheet(
                        .sheet(.playlists(track))
                    )
                },
                onShare: {
                    deferFromActionSheet(.share(track))
                },
                onCopyLink: {
                    presentedSheet = nil
                    copyTrackLink(track)
                },
                onOffline: {
                    presentedSheet = nil
                    toggleOffline(track)
                },
                onSettings: {
                    deferFromActionSheet(.sheet(.settings))
                }
            )
        }
    }

    @discardableResult
    private func present(_ sheet: PlayerSheet) -> Bool {
        guard presentedSheet == nil else { return false }
        presentedSheet = sheet
        return true
    }

    private func deferFromActionSheet(_ action: DeferredPlayerAction) {
        deferredPlayerAction = action
        presentedSheet = nil
    }

    private func handleSheetDismissal() {
        guard let action = deferredPlayerAction else { return }
        deferredPlayerAction = nil

        Task { @MainActor in
            await Task.yield()
            switch action {
            case let .sheet(sheet):
                _ = present(sheet)
            case let .share(track):
                startShare(track)
            }
        }
    }

    private var isActionSheetPresented: Bool {
        guard let presentedSheet else { return false }
        if case .actions = presentedSheet {
            return true
        }
        return false
    }

    private var queuePosition: String {
        guard let currentIndex = player.currentIndex,
              !player.queue.isEmpty else {
            return "PRIVATE MUSIC"
        }
        return L10n.format(
            "%d ИЗ %d",
            currentIndex + 1,
            player.queue.count
        )
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
                    present(.queue)
                } else if vertical > 72 {
                    closePlayer()
                }
            }
    }

    private func closePlayer() {
        presentedSheet = nil
        deferredPlayerAction = nil
        player.dismissPlayer()
    }

    private func startShare(_ track: Track) {
        Haptics.open()
        // Never present the share preparation sheet on top of another
        // player sheet — nested modal presentations crash on device.
        if presentedSheet != nil {
            deferFromActionSheet(.share(track))
            return
        }
        sharingTrack = track
    }

    private func copyTrackLink(_ track: Track) {
        let url = "https://vk.com/audio\(track.ownerID)_\(track.trackID)"
        UIPasteboard.general.string = url
        Haptics.selection()
        showCopiedToast = true

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            showCopiedToast = false
        }
    }

    private func toggleLibrary(_ track: Track) {
        guard !isUpdatingLibrary,
              sessionStore.accessToken != nil else {
            return
        }
        let removing = isInLibrary
        isUpdatingLibrary = true
        Task {
            defer { isUpdatingLibrary = false }
            do {
                if removing {
                    let stored = libraryStore.storedTrack(for: track) ?? track
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.removeFromLibrary(
                            stored,
                            accessToken: token
                        )
                    }
                    libraryStore.markRemoved(track)
                    libraryStore.markRemoved(stored)
                    MusicLibraryEvents.postRemoved(stored)
                    if player.currentTrack?.id == track.id {
                        isInLibrary = false
                    }
                } else {
                    let added = try await environment.withAuthorizedToken {
                        token in
                        try await environment.musicService.addToLibrary(
                            track,
                            accessToken: token
                        )
                    }
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
                player.errorMessage = L10n.format(
                    removing
                        ? "Не удалось удалить трек: %@"
                        : "Не удалось добавить трек: %@",
                    error.localizedDescription
                )
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

    private func toggleOffline(_ track: Track) {
        Task {
            do {
                if offlineStore.contains(track) {
                    offlineStore.remove(track)
                } else {
                    try await environment.downloadForOffline(track)
                }
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                player.errorMessage = L10n.format(
                    "Не удалось сохранить трек офлайн: %@",
                    error.localizedDescription
                )
            }
        }
    }
}

enum PlayerLayoutMode: Equatable {
    case compact
    case standard
    case tall
    case landscape
}

struct PlayerLayoutMetrics: Equatable {
    let mode: PlayerLayoutMode
    let usesAccessibilityText: Bool
    let contentWidth: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let headerHeight: CGFloat
    let headerTopPadding: CGFloat
    let artworkSize: CGFloat
    let artworkTopSpacing: CGFloat
    let metadataTopSpacing: CGFloat
    let progressTopSpacing: CGFloat
    let controlsTopSpacing: CGFloat
    let primaryControlsHeight: CGFloat
    let quickActionsTopSpacing: CGFloat
    let quickActionsHeight: CGFloat
    let bottomPadding: CGFloat
    let landscapeColumnSpacing: CGFloat
    let minimumContentHeight: CGFloat

    static func resolve(
        containerSize: CGSize,
        safeBottom: CGFloat = 0,
        safeLeading: CGFloat = 0,
        safeTrailing: CGFloat = 0,
        usesAccessibilityText: Bool = false,
        hasAlbum: Bool = true
    ) -> PlayerLayoutMetrics {
        let isLandscape =
            containerSize.width > containerSize.height * 1.12
        let mode: PlayerLayoutMode
        if isLandscape {
            mode = .landscape
        } else if containerSize.height < 720 {
            mode = .compact
        } else if containerSize.height < 860 {
            mode = .standard
        } else {
            mode = .tall
        }

        let portraitProgress = min(
            max((containerSize.height - 667) / (932 - 667), 0),
            1
        )
        func portraitValue(
            _ compact: CGFloat,
            _ tall: CGFloat
        ) -> CGFloat {
            compact + (tall - compact) * portraitProgress
        }
        let baseHorizontalPadding: CGFloat = mode == .landscape
            ? 14
            : portraitValue(18, 22)
        let leadingPadding = max(
            baseHorizontalPadding,
            safeLeading + (mode == .landscape ? 8 : 0)
        )
        let trailingPadding = max(
            baseHorizontalPadding,
            safeTrailing + (mode == .landscape ? 8 : 0)
        )
        let contentWidth = max(
            containerSize.width - leadingPadding - trailingPadding,
            0
        )

        let headerHeight: CGFloat = 44
        let headerTopPadding: CGFloat
        let artworkTopSpacing: CGFloat
        let metadataTopSpacing: CGFloat
        let progressTopSpacing: CGFloat
        let controlsTopSpacing: CGFloat
        let quickActionsTopSpacing: CGFloat
        let artworkRatio: CGFloat

        if mode == .landscape {
            headerTopPadding = 2
            artworkTopSpacing = 2
            metadataTopSpacing = 0
            progressTopSpacing = 4
            controlsTopSpacing = 4
            quickActionsTopSpacing = 4
            artworkRatio = 0.55
        } else {
            headerTopPadding = portraitValue(4, 10)
            artworkTopSpacing = portraitValue(8, 20)
            metadataTopSpacing = portraitValue(8, 12)
            progressTopSpacing = portraitValue(6, 10)
            controlsTopSpacing = portraitValue(4, 9)
            quickActionsTopSpacing = portraitValue(6, 8)
            artworkRatio = portraitValue(0.35, 0.42)
        }

        let primaryControlsHeight: CGFloat = 60
        let quickActionsHeight: CGFloat =
            usesAccessibilityText ? 72 : 64
        let bottomPadding = max(
            safeBottom,
            mode == .landscape ? 6 : 10
        )
        let metadataHeight: CGFloat
        if usesAccessibilityText {
            metadataHeight = hasAlbum ? 100 : 78
        } else {
            metadataHeight = hasAlbum ? 68 : 54
        }
        let progressHeight: CGFloat = usesAccessibilityText ? 45 : 39

        let artworkSize: CGFloat
        let minimumContentHeight: CGFloat
        if mode == .landscape {
            let availableMainHeight = max(
                containerSize.height
                    - headerTopPadding
                    - headerHeight
                    - artworkTopSpacing
                    - quickActionsTopSpacing
                    - quickActionsHeight
                    - bottomPadding,
                0
            )
            let rightColumnMinimum =
                metadataHeight
                + progressTopSpacing
                + progressHeight
                + controlsTopSpacing
                + primaryControlsHeight
            artworkSize = max(
                min(
                    min(
                        contentWidth * 0.36,
                        containerSize.height * artworkRatio
                    ),
                    availableMainHeight
                ),
                min(112, availableMainHeight)
            )
            minimumContentHeight =
                headerTopPadding
                + headerHeight
                + artworkTopSpacing
                + max(artworkSize, rightColumnMinimum)
                + quickActionsTopSpacing
                + quickActionsHeight
                + bottomPadding
        } else {
            let fixedWithoutArtwork =
                headerTopPadding
                + headerHeight
                + artworkTopSpacing
                + metadataTopSpacing
                + metadataHeight
                + progressTopSpacing
                + progressHeight
                + controlsTopSpacing
                + primaryControlsHeight
                + quickActionsTopSpacing
                + quickActionsHeight
                + bottomPadding
            let availableArtworkHeight = max(
                containerSize.height - fixedWithoutArtwork,
                0
            )
            artworkSize = max(
                min(
                    min(
                        contentWidth,
                        containerSize.height * artworkRatio
                    ),
                    availableArtworkHeight
                ),
                min(112, availableArtworkHeight)
            )
            minimumContentHeight = fixedWithoutArtwork + artworkSize
        }

        return PlayerLayoutMetrics(
            mode: mode,
            usesAccessibilityText: usesAccessibilityText,
            contentWidth: contentWidth,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding,
            headerHeight: headerHeight,
            headerTopPadding: headerTopPadding,
            artworkSize: artworkSize,
            artworkTopSpacing: artworkTopSpacing,
            metadataTopSpacing: metadataTopSpacing,
            progressTopSpacing: progressTopSpacing,
            controlsTopSpacing: controlsTopSpacing,
            primaryControlsHeight: primaryControlsHeight,
            quickActionsTopSpacing: quickActionsTopSpacing,
            quickActionsHeight: quickActionsHeight,
            bottomPadding: bottomPadding,
            landscapeColumnSpacing: mode == .landscape ? 20 : 0,
            minimumContentHeight: minimumContentHeight
        )
    }

    func quickActionsBottomY(containerHeight: CGFloat) -> CGFloat {
        max(containerHeight - bottomPadding, 0)
    }

    func requiresAccessibilityScrolling(containerHeight: CGFloat) -> Bool {
        mode == .landscape
            && usesAccessibilityText
            && minimumContentHeight > containerHeight + 0.5
    }
}

private enum PlayerSheet: Identifiable {
    case queue
    case lyrics(Track)
    case artist(String)
    case playlists(Track)
    case settings
    case actions(Track)

    var id: String {
        switch self {
        case .queue:
            return "queue"
        case let .lyrics(track):
            return "lyrics-\(track.id)"
        case let .artist(artist):
            return "artist-\(artist)"
        case let .playlists(track):
            return "playlists-\(track.id)"
        case .settings:
            return "settings"
        case let .actions(track):
            return "actions-\(track.id)"
        }
    }
}

private enum DeferredPlayerAction {
    case sheet(PlayerSheet)
    case share(Track)
}

struct PlayerActionAvailability: Equatable {
    let canModifyLibrary: Bool
    let canAddToPlaylist: Bool
    let canShare: Bool
    let showsLibraryProgress: Bool
    let showsOfflineControls: Bool

    init(
        hasSession: Bool,
        isUpdatingLibrary: Bool,
        showsOfflineControls: Bool = OfflineDownloadsFeature.showsControls
    ) {
        canModifyLibrary = hasSession && !isUpdatingLibrary
        canAddToPlaylist = hasSession
        canShare = true
        showsLibraryProgress = isUpdatingLibrary
        self.showsOfflineControls = showsOfflineControls
    }
}

enum PlayerActionSheetMetrics {
    static let preferredHeight: CGFloat = 520
    static let minimumTapTarget: CGFloat = 52
}

private struct PlayerActionsSheet: View {
    let track: Track
    let isInLibrary: Bool
    let offlineState: OfflineTrackState
    let availability: PlayerActionAvailability
    @Binding var equalizerEnabled: Bool
    @EnvironmentObject private var player: AudioPlayer
    @State private var showsSleepTimerOptions = false
    let onDismiss: () -> Void
    let onLibrary: () -> Void
    let onArtist: () -> Void
    let onPlaylist: () -> Void
    let onShare: () -> Void
    let onCopyLink: () -> Void
    let onOffline: () -> Void
    let onSettings: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack {
            ThemeBackground()

            VStack(spacing: 0) {
                header
                    .adaptiveGlass(
                        in: RoundedRectangle(
                            cornerRadius: PremiumLayout.cardRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        libraryAction

                        sectionTitle("Действия с треком")
                        LazyVGrid(columns: columns, spacing: 10) {
                            actionTile(
                                "Исполнитель",
                                systemImage: "person.wave.2",
                                action: onArtist
                            )
                            actionTile(
                                "Добавить в плейлист",
                                systemImage: "rectangle.stack.badge.plus",
                                enabled: availability.canAddToPlaylist,
                                action: onPlaylist
                            )
                            actionTile(
                                "Поделиться аудиофайлом",
                                systemImage: "square.and.arrow.up",
                                enabled: availability.canShare,
                                action: onShare
                            )
                            actionTile(
                                "Скопировать ссылку VK",
                                systemImage: "link",
                                action: onCopyLink
                            )
                            if availability.showsOfflineControls {
                                actionTile(
                                    offlineTitle,
                                    systemImage: offlineImage,
                                    enabled: offlineState != .downloading,
                                    action: onOffline
                                )
                            }
                            actionTile(
                                "Настройки звука",
                                systemImage: "slider.horizontal.3",
                                action: onSettings
                            )
                        }

                        sectionTitle("Плеер и аудио")
                        audioControls

                        Text(L10n.text("Качество: автоматически VK"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, PremiumLayout.screenPadding)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([
            .height(PlayerActionSheetMetrics.preferredHeight),
            .large
        ])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            L10n.text("Остановить воспроизведение через…"),
            isPresented: $showsSleepTimerOptions,
            titleVisibility: .visible
        ) {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(L10n.minutes(minutes)) {
                    player.scheduleSleepTimer(minutes: minutes)
                    Haptics.success()
                }
            }
            if player.sleepTimerEndDate != nil {
                Button(
                    L10n.text("Отключить таймер"),
                    role: .destructive
                ) {
                    player.cancelSleepTimer()
                    Haptics.selection()
                }
            }
            Button(L10n.text("Отмена"), role: .cancel) {}
        }
    }

    private var audioControls: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $equalizerEnabled) {
                actionRowLabel(
                    "Эквалайзер",
                    systemImage: "waveform"
                )
            }
            .tint(.accentColor)
            .padding(.horizontal, 16)
            .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)

            Divider()
                .padding(.leading, 58)

            Button {
                Haptics.open()
                showsSleepTimerOptions = true
            } label: {
                HStack(spacing: 12) {
                    actionRowLabel(
                        "Таймер сна",
                        systemImage: "moon.zzz"
                    )
                    Spacer()
                    if let endDate = player.sleepTimerEndDate {
                        Text(endDate, style: .timer)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: PlayerActionSheetMetrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityLabel(L10n.text("Таймер сна"))
        }
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            )
        )
    }

    private func actionRowLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label {
            Text(L10n.text(title))
                .font(.body.weight(.semibold))
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: Circle())
        }
    }

    private var offlineTitle: String {
        switch offlineState {
        case .remote:
            return "Скачать офлайн"
        case .downloading:
            return "Загрузка…"
        case .available:
            return "Удалить загрузку"
        }
    }

    private var offlineImage: String {
        switch offlineState {
        case .remote:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "checkmark.circle.fill"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncArtwork(url: track.artworkURL, size: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Закрыть"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var libraryAction: some View {
        Button(
            role: isInLibrary ? .destructive : nil,
            action: onLibrary
        ) {
            HStack(spacing: 12) {
                Image(
                    systemName: isInLibrary
                        ? "heart.slash"
                        : "heart"
                )
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    isInLibrary ? Color.red : Color.accentColor
                )
                .frame(width: 34, height: 34)
                .background(
                    (isInLibrary ? Color.red : Color.accentColor)
                        .opacity(0.12),
                    in: Circle()
                )

                Text(
                    L10n.text(
                        isInLibrary
                            ? "Удалить из медиатеки"
                            : "Добавить в медиатеку"
                    )
                )
                .font(.body.weight(.semibold))

                Spacer()

                if availability.showsLibraryProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(
                minHeight: PlayerActionSheetMetrics.minimumTapTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .foregroundStyle(Color.primary)
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            ),
            interactive: true,
            tint: (isInLibrary ? Color.red : Color.accentColor).opacity(0.08)
        )
        .disabled(!availability.canModifyLibrary)
        .padding(.top, 14)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.7)
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    private func actionTile(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Circle()
                    )
                Text(L10n.text(title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 66, alignment: .topLeading)
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .foregroundStyle(Color.primary)
        .adaptiveGlass(in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            ),
            interactive: true
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(L10n.text(title))
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    let tintColor: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(
        _ picker: AVRoutePickerView,
        context: Context
    ) {
        picker.tintColor = tintColor
        picker.activeTintColor = tintColor
    }
}

private struct CompactPlayerSlider: UIViewRepresentable {
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    let tintColor: UIColor
    let onEditingBegan: () -> Void
    let onCommit: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.isContinuous = true
        configureColors(slider)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingBegan(_:)),
            for: .touchDown
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        configureColors(slider)
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(max(range.upperBound, range.lowerBound + 1))
        guard !slider.isTracking else { return }
        let safeValue = value.isFinite ? value : range.lowerBound
        slider.setValue(
            Float(min(max(safeValue, range.lowerBound), range.upperBound)),
            animated: false
        )
    }

    private func configureColors(_ slider: UISlider) {
        slider.minimumTrackTintColor = tintColor
        slider.maximumTrackTintColor = tintColor.withAlphaComponent(0.18)
        slider.setThumbImage(
            makeThumb(diameter: 12),
            for: .normal
        )
        slider.setThumbImage(
            makeThumb(diameter: 15),
            for: .highlighted
        )
    }

    private func makeThumb(diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.28).cgColor
            )
            tintColor.setFill()
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
            if !slider.isTracking {
                parent.onEditingBegan()
            }
            parent.value = TimeInterval(slider.value)
            if !slider.isTracking {
                parent.onCommit(TimeInterval(slider.value))
            }
        }

        @objc
        func editingBegan(_ slider: UISlider) {
            parent.onEditingBegan()
        }

        @objc
        func editingEnded(_ slider: UISlider) {
            parent.value = TimeInterval(slider.value)
            parent.onCommit(TimeInterval(slider.value))
        }
    }
}

private struct PlayerControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: AppSettings

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(settings.theme == .light ? .black : .white)
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.96 : 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}
