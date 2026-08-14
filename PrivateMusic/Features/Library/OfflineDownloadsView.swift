import SwiftUI

struct OfflineDownloadsView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Highlight only: observing `AudioPlayer` here would rebuild the whole
    /// downloads list on every buffering / duration tick. Playback actions go
    /// through `environment.player`.
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(OfflineTrackStore.self) private var offlineStore
    @Environment(SessionStore.self) private var sessionStore
    private let offlinePlaylists =
        OfflinePlaylistStore.shared

    private enum DownloadsSection: String, CaseIterable, Identifiable {
        case tracks
        case playlists
        case cache

        var id: Self { self }

        var title: String {
            switch self {
            case .tracks: return L10n.text("library.tracks")
            case .playlists: return L10n.text("library.playlists")
            case .cache: return L10n.text("auto_cache")
            }
        }
    }

    @State private var section: DownloadsSection = .tracks
    @State private var searchText = ""
    @State private var selection: Set<String>?
    @State private var sharingTrack: Track?
    @State private var selectedRecord: OfflineTrackRecord?
    @State private var deferredShareTrack: Track?
    @State private var showsDeleteConfirmation = false
    @State private var showsDeleteAllConfirmation = false
    @State private var showsClearCacheConfirmation = false
    @State private var pendingPlaylistRemoval: PlaylistSection?
    @State private var showsDeletePlaylistConfirmation = false

    var body: some View {
        List {
            Section {
                DownloadStorageSummary(
                    usage: offlineStore.storageUsage,
                    onClearCache: {
                        showsClearCacheConfirmation = true
                    },
                    onDeleteAll: {
                        showsDeleteAllConfirmation = true
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if activeDownloadCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("downloading_3"))
                                .font(.subheadline.weight(.semibold))
                            Text(
                                L10n.format(
                                    "active_downloads_d0",
                                    activeDownloadCount
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Picker(L10n.text("section"), selection: $section) {
                    ForEach(DownloadsSection.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch section {
            case .tracks:
                tracksSection(manualRecords)
            case .cache:
                cacheSection(cacheRecords)
            case .playlists:
                playlistsSections
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: 0.3), value: contentSnapshot)
        .background(ThemeBackground())
        .scrollContentBackground(.hidden)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selection != nil)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: L10n.text("title_or_artist")
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selection != nil {
                    Button(L10n.text("action.cancel")) {
                        exitSelection()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selection != nil {
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label(L10n.text("action.delete"), systemImage: "trash")
                    }
                    .disabled(selection?.isEmpty != false)
                } else if section != .playlists,
                          !recordsForCurrentSection.isEmpty {
                    Button(L10n.text("select")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = []
                        }
                    }
                }
            }
        }
        .trackShareSheet(track: $sharingTrack)
        .sheet(
            item: $selectedRecord,
            onDismiss: presentDeferredShareIfNeeded
        ) { record in
            DownloadedTrackDetailsView(
                record: record,
                localURL: offlineStore.localURL(for: record.track),
                onPlay: {
                    environment.player.play(
                        record.track,
                        in: validRecords.map(\.track)
                    )
                },
                onShare: {
                    deferredShareTrack = record.track
                    selectedRecord = nil
                },
                onDelete: {
                    deleteTrack(record.track)
                }
            )
        }
        .confirmationDialog(
            L10n.format(
                "delete_selected_d0",
                selection?.count ?? 0
            ),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("action.delete"), role: .destructive) {
                removeSelectedTracks()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.text("delete_all_downloads_from_this_device"),
            isPresented: $showsDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("delete_all"), role: .destructive) {
                deleteAll()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.text("clear_all_auto_cache_files"),
            isPresented: $showsClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("clear"), role: .destructive) {
                clearAutomaticCache()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.text("delete_playlist"),
            isPresented: $showsDeletePlaylistConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("remove_playlist"), role: .destructive) {
                removePlaylist(pendingPlaylistRemoval)
            }
            if let section = pendingPlaylistRemoval,
               hasUnusedLocalFiles(in: section) {
                Button(
                    L10n.text("delete_playlist_and_audio_files"),
                    role: .destructive
                ) {
                    removePlaylistAndFiles(pendingPlaylistRemoval)
                }
            }
            Button(L10n.text("action.cancel"), role: .cancel) {
                pendingPlaylistRemoval = nil
            }
        } message: {
            Text(
                L10n.text("audio_files_will_remain_in_the_tracks_section_if_you_only_delete_the_pla")
            )
        }
        .task(id: sessionStore.resolvedOfflineAccountID) {
            offlinePlaylists.configure(
                accountID: sessionStore.resolvedOfflineAccountID
            )
            offlineStore.configure(
                accountID: sessionStore.resolvedOfflineAccountID
            )
            offlineStore.reconcile()
            offlinePlaylists.reconcileDownloads(with: offlineStore)
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

    private var validRecords: [OfflineTrackRecord] {
        offlineStore.records.values
            .filter { offlineStore.localURL(for: $0.track) != nil }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    private var manualRecords: [OfflineTrackRecord] {
        filtered(validRecords.filter {
            $0.resolvedRetention == .manual
        })
    }

    private var cacheRecords: [OfflineTrackRecord] {
        filtered(validRecords.filter {
            $0.resolvedRetention == .automaticCache
        })
    }

    private var recordsForCurrentSection: [OfflineTrackRecord] {
        switch section {
        case .tracks: return manualRecords
        case .cache: return cacheRecords
        case .playlists: return []
        }
    }

    private func filtered(
        _ values: [OfflineTrackRecord]
    ) -> [OfflineTrackRecord] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return values }
        return values.filter {
            $0.track.title.localizedCaseInsensitiveContains(query)
                || $0.track.artist.localizedCaseInsensitiveContains(query)
                || ($0.track.albumTitle?
                    .localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var allPlaylistSections: [PlaylistSection] {
        offlinePlaylists.records.values
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
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Finished playlists plus errored records that still carry local
    /// tracks. Empty failed/cancelled records are hidden entirely.
    private var downloadedSections: [PlaylistSection] {
        allPlaylistSections.filter { section in
            guard !OfflinePlaylistStatus.status(for: section.record).isActive
            else {
                return false
            }
            return PlaylistDownloadsVisibility.shouldShowDownloaded(
                section.record,
                hasLocalTracks: !section.tracks.isEmpty
            )
        }
        .sorted { $0.record.updatedAt > $1.record.updatedAt }
    }

    private var activeDownloadCount: Int {
        let playlistTrackIDs = Set(
            activeSections.flatMap(\.allTracks).map(\.id)
        )
        return OfflineDownloadsPresentation.activeDownloadCount(
            downloadingTrackIDs: offlineStore.downloadingTrackIDs,
            activePlaylistTrackIDs: playlistTrackIDs,
            activePlaylistCount: activeSections.count
        )
    }

    private var contentSnapshot: [String] {
        validRecords.map(\.id)
            + activeSections.map(\.id)
            + downloadedSections.map(\.id)
    }

    // MARK: - Sections

    @ViewBuilder
    private func tracksSection(
        _ records: [OfflineTrackRecord]
    ) -> some View {
        if records.isEmpty {
            emptySection(
                title: searchText.isEmpty
                    ? "no_saved_tracks"
                    : "no_results",
                systemImage: "music.note",
                description: searchText.isEmpty
                    ? "downloaded_tracks_will_appear_here"
                    : "try_a_different_search_query"
            )
        } else {
            Section {
                ForEach(records) { record in
                    downloadedTrackRow(record)
                }
            }
        }
    }

    @ViewBuilder
    private func cacheSection(
        _ records: [OfflineTrackRecord]
    ) -> some View {
        if records.isEmpty {
            emptySection(
                title: searchText.isEmpty
                    ? "auto_cache_is_empty"
                    : "no_results",
                systemImage: "bolt.horizontal",
                description: searchText.isEmpty
                    ? "listened_tracks_saved_temporarily"
                    : "try_a_different_search_query"
            )
        } else {
            Section {
                ForEach(records) { record in
                    downloadedTrackRow(record)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSections: some View {
        let active = filteredSections(activeSections)
        let done = filteredSections(downloadedSections)
        if active.isEmpty && done.isEmpty {
            emptySection(
                title: searchText.isEmpty
                    ? "no_playlists"
                    : "no_results",
                systemImage: "rectangle.stack",
                description: searchText.isEmpty
                    ? "downloaded_playlists_will_appear_here"
                    : "try_a_different_search_query"
            )
        } else {
            if !active.isEmpty {
                Section {
                    ForEach(active) { section in
                        activeDownloadRow(section)
                            .transition(.opacity)
                    }
                } header: {
                    Text(L10n.text("active_downloads"))
                }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { section in
                        downloadedPlaylistRow(section)
                            .transition(.opacity)
                    }
                } header: {
                    Text(L10n.text("downloaded_playlists"))
                }
            }
        }
    }

    private func filteredSections(
        _ sections: [PlaylistSection]
    ) -> [PlaylistSection] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return sections }
        return sections.filter {
            $0.playlist.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func emptySection(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        Section {
            EmptyStateView(
                title: title,
                systemImage: systemImage,
                description: description
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Track rows

    private func downloadedTrackRow(
        _ record: OfflineTrackRecord
    ) -> some View {
        DownloadedTrackRow(
            record: record,
            isPlaying: highlight.isCurrent(record.track.id),
            isSelectionMode: selection != nil,
            isSelected: selection?.contains(record.track.id) == true,
            onPlay: {
                if selection != nil {
                    toggleSelection(record.track)
                } else {
                    environment.player.play(
                        record.track,
                        in: validRecords.map(\.track)
                    )
                }
            },
            onShare: {
                sharingTrack = record.track
            },
            onInfo: {
                selectedRecord = record
            },
            onDelete: {
                deleteTrack(record.track)
            },
            onLongPress: {
                guard selection == nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = [record.track.id]
                }
                Haptics.selection()
            },
            onToggleSelection: {
                toggleSelection(record.track)
            }
        )
    }

    // MARK: - Active playlist rows

    private func activeDownloadRow(
        _ section: PlaylistSection
    ) -> some View {
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
                    if let statusText = status.localizedText?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        NavigationLink {
            PlaylistDownloadsDetailView(
                title: section.playlist.title,
                records: section.tracks.compactMap {
                    offlineStore.record(for: $0)
                },
                onPlay: { record in
                    environment.player.play(
                        record.track,
                        in: section.tracks
                    )
                },
                onShare: { record in
                    sharingTrack = record.track
                },
                onInfo: { record in
                    selectedRecord = record
                },
                onDelete: { record in
                    deleteTrack(record.track)
                }
            )
        } label: {
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
                        Text(
                            L10n.format("downloaded_d0_of_d1", count, total)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(
                            message
                                ?? L10n.text("couldn_t_download_the_playlist")
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    case .cancelled:
                        Text(L10n.text("download_cancelled"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    default:
                        Text(
                            L10n.format(
                                "d0_of_d1_2",
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
                    Button(L10n.text("action.retry")) {
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
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingPlaylistRemoval = section
                showsDeletePlaylistConfirmation = true
            } label: {
                Label(L10n.text("action.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Playlist detail

    private struct PlaylistDownloadsDetailView: View {
        @Environment(PlaybackHighlightModel.self) private var highlight

        let title: String
        let records: [OfflineTrackRecord]
        let onPlay: (OfflineTrackRecord) -> Void
        let onShare: (OfflineTrackRecord) -> Void
        let onInfo: (OfflineTrackRecord) -> Void
        let onDelete: (OfflineTrackRecord) -> Void

        var body: some View {
            List {
                if records.isEmpty {
                    Section {
                        EmptyStateView(
                            title: "no_available_tracks",
                            systemImage: "music.note",
                            description:
                                "playlist_has_no_local_files"
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(records) { record in
                            DownloadedTrackRow(
                                record: record,
                                isPlaying: highlight.isCurrent(
                                    record.track.id
                                ),
                                isSelectionMode: false,
                                isSelected: false,
                                onPlay: { onPlay(record) },
                                onShare: { onShare(record) },
                                onInfo: { onInfo(record) },
                                onDelete: { onDelete(record) },
                                onLongPress: {},
                                onToggleSelection: {}
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ThemeBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Actions

    /// Presents the share sheet only after the details sheet has fully
    /// dismissed; presenting two sheets at once is not supported by SwiftUI.
    private func presentDeferredShareIfNeeded() {
        guard let track = deferredShareTrack else { return }
        deferredShareTrack = nil
        sharingTrack = track
    }

    private func retryDownload(_ section: PlaylistSection) {        offlinePlaylists.startDownload(
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

    private func deleteTrack(_ track: Track) {
        offlineStore.remove(track)
        offlinePlaylists.reconcileDownloads(with: offlineStore)
        Haptics.selection()
    }

    // MARK: - Playlist deletion

    /// Local files of this playlist that no other playlist references. Only
    /// these may be offered for deletion together with the playlist record.
    private func unusedLocalFiles(
        in section: PlaylistSection
    ) -> [Track] {
        let referencedByOthers = Set(
            offlinePlaylists.records.values
                .filter { $0.id != section.record.id }
                .flatMap(\.tracks)
                .map(\.id)
        )
        return section.tracks.filter {
            offlineStore.contains($0)
                && !referencedByOthers.contains($0.id)
        }
    }

    private func hasUnusedLocalFiles(in section: PlaylistSection) -> Bool {
        !unusedLocalFiles(in: section).isEmpty
    }

    private func removePlaylist(_ section: PlaylistSection?) {
        guard let section else { return }
        pendingPlaylistRemoval = nil
        offlinePlaylists.remove(section.playlist)
        offlinePlaylists.reconcileDownloads(with: offlineStore)
        Haptics.selection()
    }

    /// Removes the playlist record and, separately, the audio files that no
    /// other playlist references. Shared tracks are kept untouched.
    private func removePlaylistAndFiles(_ section: PlaylistSection?) {
        guard let section else { return }
        pendingPlaylistRemoval = nil
        for track in unusedLocalFiles(in: section) {
            offlineStore.remove(track)
        }
        offlinePlaylists.remove(section.playlist)
        offlinePlaylists.reconcileDownloads(with: offlineStore)
        Haptics.selection()
    }

    private func clearAutomaticCache() {
        offlineStore.removeAutomaticCache()
        offlinePlaylists.reconcileDownloads(with: offlineStore)
        Haptics.selection()
    }

    private func deleteAll() {
        exitSelection()
        Task {
            offlinePlaylists.removeAll()
            await offlineStore.removeAll()
        }
    }

    // MARK: - Selection

    private var navigationTitle: String {
        guard let selection else {
            return L10n.text("downloads")
        }
        return L10n.format("selected_d0", selection.count)
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
        let tracks = validRecords.filter {
            selected.contains($0.track.id)
        }
        for record in tracks {
            offlineStore.remove(record.track)
        }
        offlinePlaylists.reconcileDownloads(with: offlineStore)
        exitSelection()
    }
}

enum OfflineDownloadsPresentation {
    static func activeDownloadCount(
        downloadingTrackIDs: Set<String>,
        activePlaylistTrackIDs: Set<String>,
        activePlaylistCount: Int
    ) -> Int {
        downloadingTrackIDs
            .subtracting(activePlaylistTrackIDs)
            .count + max(activePlaylistCount, 0)
    }
}

// MARK: - Playlist download visibility

/// Decides whether a finished playlist download is shown in the
/// «Скачанные плейлисты» section. Failed/cancelled records appear only
/// while they still have local audio files — a record whose tracks are
/// metadata-only (files were deleted) is stale and hidden.
enum PlaylistDownloadsVisibility {
    static func shouldShowDownloaded(
        _ record: OfflinePlaylistRecord,
        hasLocalTracks: Bool
    ) -> Bool {
        switch record.state {
        case .available, .partial:
            return true
        case .failed, .cancelled:
            return hasLocalTracks
        case .idle, .resolvingTracks, .queued, .downloading:
            return false
        }
    }
}

// MARK: - Downloaded track row

private struct DownloadedTrackRow: View {
    let record: OfflineTrackRecord
    let isPlaying: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onPlay: () -> Void
    let onShare: () -> Void
    let onInfo: () -> Void
    let onDelete: () -> Void
    let onLongPress: () -> Void
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(
                    systemName: isSelected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                    isSelected ? Color.accentColor : Color.secondary
                )
            }

            Button(action: isSelectionMode ? onToggleSelection : onPlay) {
                HStack(spacing: 12) {
                    AsyncArtwork(url: record.track.artworkURL, size: 50)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(record.track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(formattedBytes(record.byteCount))
                            Text("·")
                            Text(
                                record.resolvedRetention == .manual
                                    ? L10n.text("downloaded")
                                    : L10n.text("auto_cache")
                            )
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !isSelectionMode {
                        LikedTrackBadge(track: record.track)
                        Image(
                            systemName: isPlaying
                                ? "waveform"
                                : "play.circle.fill"
                        )
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isSelectionMode {
                Menu {
                    Button(action: onPlay) {
                        Label(L10n.text("play"), systemImage: "play.fill")
                    }
                    Button(action: onShare) {
                        Label(L10n.text("share_audio_file"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    Button(action: onInfo) {
                        Label(L10n.text("file_details"),
                            systemImage: "info.circle"
                        )
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(L10n.text("remove_download"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button(action: onShare) {
                    Label(L10n.text("share"), systemImage: "square.and.arrow.up")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isSelectionMode {
                Button(role: .destructive, action: onDelete) {
                    Label(L10n.text("action.delete"), systemImage: "trash")
                }
            }
        }
        .onLongPressGesture {
            onLongPress()
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}

// MARK: - Storage summary

/// Text lines for the storage card, kept testable: the subtitle must show
/// the full stored audio size against the configured limit, and the
/// breakdown must cover manual, cache and overhead bytes.
enum DownloadStorageText {
    static func summary(
        usage: StorageUsage,
        formatBytes: (Int64) -> String
    ) -> (subtitle: String, manual: String, cache: String, overhead: String) {
        let overheadBytes = max(0, usage.totalBytes - usage.audioBytes)
        return (
            subtitle: L10n.format(
                "n_0_of_1",
                formatBytes(usage.audioBytes),
                formatBytes(usage.limitBytes)
            ),
            manual: L10n.format(
                "my_downloads_0_2",
                formatBytes(usage.manualBytes)
            ),
            cache: L10n.format(
                "automatic_cache_0",
                formatBytes(usage.automaticBytes)
            ),
            overhead: L10n.format(
                "service_data_0",
                formatBytes(overheadBytes)
            )
        )
    }
}

private struct DownloadStorageSummary: View {
    let usage: StorageUsage
    let onClearCache: () -> Void
    let onDeleteAll: () -> Void

    var body: some View {
        let lines = DownloadStorageText.summary(
            usage: usage,
            formatBytes: Self.formattedBytes
        )
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    storageTitle
                    Spacer(minLength: 12)
                    storageSubtitle(lines.subtitle)
                }
                VStack(alignment: .leading, spacing: 3) {
                    storageTitle
                    storageSubtitle(lines.subtitle)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    if clampedUsageRatio > 0 {
                        Capsule()
                            .fill(
                                clampedUsageRatio > 0.9
                                    ? Color.red
                                    : Color.accentColor
                            )
                            .frame(
                                width: proxy.size.width * clampedUsageRatio
                            )
                    }
                }
            }
            .frame(height: 6)

            Text(L10n.text("available_offline_3"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(lines.manual)
                Text(lines.cache)
                Text(lines.overhead)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    clearCacheButton
                    deleteAllButton
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) {
                    clearCacheButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                    deleteAllButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var clampedUsageRatio: CGFloat {
        CGFloat(min(max(usage.usageRatio, 0), 1))
    }

    private var storageTitle: some View {
        Text(L10n.text("downloads_on_this_device"))
            .font(.headline)
    }

    private func storageSubtitle(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var clearCacheButton: some View {
        Button(action: onClearCache) {
            Label(
                L10n.text("clear_automatic_cache"),
                systemImage: "broom"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(usage.automaticBytes <= 0)
    }

    private var deleteAllButton: some View {
        Button(role: .destructive, action: onDeleteAll) {
            Label(
                L10n.text("delete_all"),
                systemImage: "trash"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(usage.totalCount <= 0)
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
