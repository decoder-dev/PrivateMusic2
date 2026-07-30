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
    @State private var presentedSheet: PlayerSheet?
    @State private var deferredPlayerAction: DeferredPlayerAction?
    @State private var shareCleanupURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var isPreparingShare = false
    @State private var isInLibrary = false
    @State private var isUpdatingLibrary = false
    @State private var scrubPosition: TimeInterval?
    private let shareService = TrackShareService()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                artworkBackground

                if let track = player.currentTrack {
                    playerContent(
                        track,
                        size: proxy.size,
                        bottomInset: proxy.safeAreaInsets.bottom
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
        .dynamicTypeSize(...DynamicTypeSize.large)
        .ignoresSafeArea(edges: .bottom)
        .sheet(
            item: $presentedSheet,
            onDismiss: handleSheetDismissal
        ) { sheet in
            presentedSheetContent(sheet)
        }
        .onChange(of: player.currentTrack?.id) { _ in
            shareTask?.cancel()
            shareTask = nil
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
        .onDisappear {
            shareTask?.cancel()
            shareTask = nil
            if !isPresentingShareSheet {
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
        size: CGSize,
        bottomInset: CGFloat
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
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.08), in: Circle())
                            .overlay {
                                Circle().stroke(
                                    .white.opacity(0.08),
                                    lineWidth: 0.5
                                )
                            }
                    }
                    .buttonStyle(PlayerControlStyle())
                    .accessibilityLabel(L10n.text("Закрыть плеер"))
                    Spacer()
                    HStack(spacing: 8) {
                        AirPlayRoutePicker()
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.08), in: Circle())
                            .overlay {
                                Circle().stroke(
                                    .white.opacity(0.08),
                                    lineWidth: 0.5
                                )
                            }
                            .accessibilityLabel(
                                L10n.text(
                                    "Выбрать устройство воспроизведения"
                                )
                            )
                        actionMenuButton(track)
                    }
                }
            }
            .frame(height: 44)
            .padding(.top, compact ? 6 : 10)

            AsyncArtwork(url: track.artworkURL, size: artworkSize)
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
                        present(.artist(track.artist))
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
                            .foregroundStyle(.white.opacity(0.52))
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
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
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
            .padding(
                .top,
                compact ? 10 : (spacious ? 21 : 16)
            )

            VStack(spacing: 3) {
                CompactPlayerSlider(
                    value: Binding(
                        get: { displayedElapsedTime },
                        set: { scrubPosition = $0 }
                    ),
                    range: 0...max(player.duration, 1),
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
                .foregroundStyle(.white.opacity(0.52))
            }
            .padding(
                .top,
                compact ? 8 : (spacious ? 16 : 12)
            )

            VStack(spacing: compact ? 7 : 11) {
                primaryControls
                quickActions(track)
            }
            .padding(.top, compact ? 5 : (spacious ? 14 : 9))

            Spacer(
                minLength: max(
                    bottomInset,
                    compact ? 8 : 16
                )
            )
        }
        .frame(
            width: contentWidth,
            height: size.height,
            alignment: .top
        )
        .padding(.horizontal, horizontalPadding)
        .foregroundStyle(.white)
    }

    private func actionMenuButton(_ track: Track) -> some View {
        Button {
            present(.actions(track))
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 0.5)
                }
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
            .accessibilityLabel(
                L10n.text(
                    player.isPlaying
                        ? "Приостановить"
                        : "Продолжить воспроизведение"
                )
            )
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

    private func quickActions(_ track: Track) -> some View {
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
                Text(L10n.text(title))
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
        accessibilityValue: String,
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
        case let .share(fileURL):
            TrackShareSheet(fileURL: fileURL)
        case let .actions(track):
            PlayerActionsSheet(
                track: track,
                isInLibrary: isInLibrary,
                availability: PlayerActionAvailability(
                    hasSession: sessionStore.accessToken != nil,
                    isUpdatingLibrary: isUpdatingLibrary,
                    isPreparingShare: isPreparingShare
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
        guard let deferredPlayerAction else {
            cleanupSharedFile()
            return
        }
        self.deferredPlayerAction = nil

        Task { @MainActor in
            await Task.yield()
            switch deferredPlayerAction {
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

    private var isPresentingShareSheet: Bool {
        guard let presentedSheet else { return false }
        if case .share = presentedSheet {
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
                    dismiss()
                }
            }
    }

    private func prepareShare(_ track: Track) async {
        guard sessionStore.accessToken != nil else {
            player.errorMessage = L10n.text(
                "Войдите во VK, чтобы экспортировать песню."
            )
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let refreshed = try await environment.withAuthorizedToken { token in
                try await environment.musicService.refreshedTrack(
                    track,
                    accessToken: token
                )
            }
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
            if isActionSheetPresented {
                deferFromActionSheet(.sheet(.share(fileURL)))
                Haptics.selection()
                return
            }
            if case .some = deferredPlayerAction {
                cleanupSharedFile()
                return
            }
            guard present(.share(fileURL)) else {
                cleanupSharedFile()
                return
            }
            Haptics.selection()
        } catch is CancellationError {
            return
        } catch {
            player.errorMessage = L10n.text(
                "Не удалось экспортировать песню. Обновите сессию VK "
                    + "или попробуйте ещё раз."
            )
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
}

private enum PlayerSheet: Identifiable {
    case queue
    case lyrics(Track)
    case artist(String)
    case playlists(Track)
    case settings
    case share(URL)
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
        case let .share(url):
            return "share-\(url.absoluteString)"
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

    init(
        hasSession: Bool,
        isUpdatingLibrary: Bool,
        isPreparingShare: Bool
    ) {
        canModifyLibrary = hasSession && !isUpdatingLibrary
        canAddToPlaylist = hasSession
        canShare = hasSession && !isPreparingShare
        showsLibraryProgress = isUpdatingLibrary
    }
}

enum PlayerActionSheetMetrics {
    static let preferredHeight: CGFloat = 520
    static let minimumTapTarget: CGFloat = 52
}

private struct PlayerActionsSheet: View {
    let track: Track
    let isInLibrary: Bool
    let availability: PlayerActionAvailability
    @Binding var equalizerEnabled: Bool
    let onDismiss: () -> Void
    let onLibrary: () -> Void
    let onArtist: () -> Void
    let onPlaylist: () -> Void
    let onShare: () -> Void
    let onSettings: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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
                            "Поделиться",
                            systemImage: "square.and.arrow.up",
                            enabled: availability.canShare,
                            action: onShare
                        )
                        actionTile(
                            "Настройки звука",
                            systemImage: "slider.horizontal.3",
                            action: onSettings
                        )
                    }

                    sectionTitle("Плеер и аудио")
                    Toggle(isOn: $equalizerEnabled) {
                        Label {
                            Text(L10n.text("Эквалайзер"))
                                .font(.body.weight(.semibold))
                        } icon: {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.accentColor)
                    .padding(.horizontal, 16)
                    .frame(
                        minHeight: PlayerActionSheetMetrics.minimumTapTarget
                    )
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous
                        )
                    )

                    Text(L10n.text("Качество: автоматически VK"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([
            .height(PlayerActionSheetMetrics.preferredHeight),
            .large
        ])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncArtwork(url: track.artworkURL, size: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
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
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Закрыть"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                .frame(width: 28)

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
        .buttonStyle(.plain)
        .foregroundStyle(isInLibrary ? Color.red : Color.primary)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .disabled(!availability.canModifyLibrary)
        .padding(.top, 14)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
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
                Text(L10n.text(title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 54, alignment: .topLeading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(L10n.text(title))
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
    let onEditingBegan: () -> Void
    let onCommit: (TimeInterval) -> Void

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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
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
