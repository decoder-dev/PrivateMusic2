import SwiftUI

struct OfflineDownloadsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    @State private var selection: Set<String>?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if offlineStore.downloadedTracks.isEmpty
                && offlinePlaylists.records.isEmpty {
                EmptyStateView(
                    title: "Нет загрузок",
                    systemImage: "arrow.down.circle",
                    description:
                        "Скачайте треки самостоятельно — они останутся "
                            + "навсегда, или включите автокэш в Настройках, "
                            + "и прослушанное будет сохраняться само."
                )
                .padding()
            } else {
                List {
                    let active = activeSections
                    if !active.isEmpty {
                        Section {
                            ForEach(active) { section in
                                activeDownloadRow(section)
                                    .transition(.opacity)
                            }
                        } header: {
                            Text(L10n.text("Активные загрузки"))
                        }
                    }

                    let done = downloadedSections
                    if !done.isEmpty {
                        Section {
                            ForEach(done) { section in
                                downloadedPlaylistRow(section)
                                    .transition(.opacity)
                            }
                        } header: {
                            Text(L10n.text("Скачанные плейлисты"))
                        }
                    }

                    let orphans = orphanTracks
                    if !orphans.isEmpty {
                        Section {
                            ForEach(orphans) { track in
                                trackRow(
                                    track,
                                    playlistTracks: orphans,
                                    inPlaylist: nil
                                )
                                .transition(.opacity)
                            }
                        } header: {
                            Text(L10n.text("Другие загрузки"))
                        }
                    }
                }
                .animation(
                    .easeInOut(duration: 0.3),
                    value: contentSnapshot
                )
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selection != nil)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selection != nil {
                    Button(L10n.text("Отмена")) {
                        exitSelection()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if hasAnyContent {
                    if selection != nil {
                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Label(
                                "Удалить",
                                systemImage: "trash"
                            )
                        }
                        .disabled(selection?.isEmpty != false)
                    } else if !orphanTracks.isEmpty {
                        Button(L10n.text("Выбрать")) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selection = []
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.format(
                "Удалить выбранные (%d)?",
                selection?.count ?? 0
            ),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Удалить"), role: .destructive) {
                removeSelectedTracks()
            }
            Button(L10n.text("Отмена"), role: .cancel) {}
        }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            offlinePlaylists.configure(
                accountID: sessionStore.resolvedOfflineAccountID
            )
            offlineStore.configure(
                accountID: sessionStore.resolvedOfflineAccountID
            )
        }
    }

    // MARK: - Data

    private struct PlaylistSection: Identifiable {
        let id: String
        let playlist: Playlist
        var tracks: [Track]
        var allTracks: [Track]
        var record: OfflinePlaylistRecord
    }

    private var allPlaylistSections: [PlaylistSection] {
        offlinePlaylists.records.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                PlaylistSection(
                    id: record.id,
                    playlist: record.playlist,
                    tracks: record.tracks.filter {
                        offlineStore.contains($0)
                    },
                    allTracks: record.tracks,
                    record: record
                )
            }
    }

    private var activeSections: [PlaylistSection] {
        allPlaylistSections.filter {
            OfflinePlaylistStatus.status(for: $0.record).isActive
        }
    }

    /// Finished playlists plus errored records that still carry tracks or a
    /// partial result. Empty failed/cancelled records are hidden entirely.
    private var downloadedSections: [PlaylistSection] {
        allPlaylistSections.filter { section in
            guard !OfflinePlaylistStatus.status(for: section.record).isActive
            else {
                return false
            }
            switch section.record.state {
            case .available, .partial:
                return true
            case .failed, .cancelled:
                return section.record.completedCount > 0
                    || !section.record.tracks.isEmpty
            case .idle, .resolvingTracks, .queued, .downloading:
                return false
            }
        }
    }

    private var orphanTracks: [Track] {
        let playlistTrackIDs = Set(
            offlinePlaylists.records.values
                .flatMap { $0.tracks }
                .map(\.id)
        )
        return offlineStore.downloadedTracks.filter {
            !playlistTrackIDs.contains($0.id)
        }
    }

    private var hasAnyContent: Bool {
        !activeSections.isEmpty
            || !downloadedSections.isEmpty
            || !orphanTracks.isEmpty
    }

    private var contentSnapshot: [String] {
        activeSections.map(\.id)
            + downloadedSections.map(\.id)
            + orphanTracks.map(\.id)
    }

    // MARK: - Active rows

    private func activeDownloadRow(_ section: PlaylistSection) -> some View {
        let status = OfflinePlaylistStatus.status(for: section.record)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PlaylistArtworkView(
                    playlist: section.playlist,
                    size: 44,
                    showsSource: false
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.playlist.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(status.localizedText ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    offlinePlaylists.cancelDownload(for: section.playlist)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let progress = status.progress {
                AnimatedProgressView(progress: progress)
                    .padding(.leading, 56)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Downloaded playlist rows

    @ViewBuilder
    private func downloadedPlaylistRow(
        _ section: PlaylistSection
    ) -> some View {
        let status = OfflinePlaylistStatus.status(for: section.record)
        HStack(spacing: 12) {
            PlaylistArtworkView(
                playlist: section.playlist,
                size: 44,
                showsSource: false
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(section.playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                switch status {
                case .partial(let count, let total):
                    Text(L10n.format("Скачано %d из %d", count, total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message ?? L10n.text("Не удалось скачать плейлист"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .cancelled:
                    Text(L10n.text("Загрузка отменена"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    Text(
                        L10n.format(
                            "%d из %d",
                            section.tracks.count,
                            section.allTracks.count
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if section.record.state == .partial
                || section.record.state == .failed
                || section.record.state == .cancelled {
                Button(L10n.text("Повторить")) {
                    retryDownload(section)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            if selection == nil {
                Button(role: .destructive) {
                    offlinePlaylists.remove(section.playlist)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Track rows

    @ViewBuilder
    private func trackRow(
        _ track: Track,
        playlistTracks: [Track],
        inPlaylist playlistID: String?
    ) -> some View {
        Button {
            if selection != nil {
                toggleSelection(track)
            } else {
                player.play(track, in: playlistTracks)
            }
        } label: {
            HStack(spacing: 12) {
                if selection != nil {
                    selectionIndicator(for: track)
                }
                AsyncArtwork(url: track.artworkURL, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selection == nil {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            guard selection == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = [track.id]
            }
            Haptics.selection()
        }
        .swipeActions {
            if selection == nil {
                Button(role: .destructive) {
                    offlineStore.remove(track)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions

    private func retryDownload(_ section: PlaylistSection) {
        offlinePlaylists.startDownload(
            playlist: section.playlist,
            fetchPage: { offset in
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.playlistTracks(
                        section.playlist,
                        accessToken: token,
                        offset: offset,
                        count: 100
                    )
                }
            },
            downloadTrack: { track in
                try await environment.downloadForOffline(track)
            }
        )
    }

    // MARK: - Selection

    private var navigationTitle: String {
        guard let selection else {
            return L10n.text("Загрузки")
        }
        return L10n.format("Выбрано: %d", selection.count)
    }

    private func selectionIndicator(for track: Track) -> some View {
        let isSelected = selection?.contains(track.id) == true
        return Image(
            systemName: isSelected
                ? "checkmark.circle.fill"
                : "circle"
        )
        .font(.title3)
        .foregroundStyle(
            isSelected ? Color.accentColor : Color.secondary
        )
    }

    private func toggleSelection(_ track: Track) {
        guard var current = selection else { return }
        if current.contains(track.id) {
            current.remove(track.id)
        } else {
            current.insert(track.id)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = current
        }
        Haptics.selection()
    }

    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = nil
        }
    }

    private func removeSelectedTracks() {
        guard let selected = selection, !selected.isEmpty else { return }
        let tracks = offlineStore.downloadedTracks.filter {
            selected.contains($0.id)
        }
        for track in tracks {
            offlineStore.remove(track)
        }
        exitSelection()
    }
}

// MARK: - Animated Progress

private struct AnimatedProgressView: View {
    let progress: Double

    @State private var animatedProgress: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: proxy.size.width
                                * animatedProgress,
                            height: 4
                        )
                        .animation(
                            .easeInOut(duration: 0.4),
                            value: animatedProgress
                        )
                }
            }
            .frame(width: 50, height: 4)
            Text("\(Int(animatedProgress * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .onAppear {
            animatedProgress = progress
        }
        .onChange(of: progress) { newProgress in
            withAnimation(.easeInOut(duration: 0.4)) {
                animatedProgress = newProgress
            }
        }
    }
}
