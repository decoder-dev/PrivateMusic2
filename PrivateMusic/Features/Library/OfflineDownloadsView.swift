import SwiftUI

struct OfflineDownloadsView: View {
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
                    if !offlinePlaylists.records.isEmpty {
                        Section("Плейлисты") {
                            ForEach(
                                offlinePlaylists.records.values.sorted {
                                    $0.updatedAt > $1.updatedAt
                                }
                            ) { record in
                                NavigationLink {
                                    OfflinePlaylistDetailView(record: record)
                                } label: {
                                    OfflinePlaylistRow(record: record)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        offlinePlaylists.remove(
                                            record.playlist
                                        )
                                    } label: {
                                        Label(
                                            "Удалить",
                                            systemImage: "trash"
                                        )
                                    }
                                }
                            }
                        }
                    }
                    if !offlineStore.manualDownloads.isEmpty {
                        Section {
                            ForEach(
                                offlineStore.manualDownloads,
                                id: \.id
                            ) { record in
                                downloadRow(for: record.track)
                            }
                        } header: {
                            Text(
                                L10n.format(
                                    "Мои загрузки · %@",
                                    formattedManualSize
                                )
                            )
                        } footer: {
                            Text(
                                L10n.text(
                                    "Сохранены вами. Удаляются только вручную."
                                )
                            )
                        }
                    }
                    if !offlineStore.automaticCacheTracks.isEmpty {
                        Section {
                            ForEach(
                                offlineStore.automaticCacheTracks,
                                id: \.id
                            ) { record in
                                downloadRow(for: record.track)
                            }
                        } header: {
                            Text(
                                L10n.format(
                                    "Автокэш · %@",
                                    formattedCacheSize
                                )
                            )
                        } footer: {
                            Text(
                                L10n.text(
                                    "Сохраняется автоматически после "
                                        + "прослушивания. Старые записи "
                                        + "удаляются первыми при заполнении "
                                        + "хранилища."
                                )
                            )
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selection != nil {
                    Button(L10n.text("Отмена")) {
                        exitSelection()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if offlineStore.downloadedTracks.isEmpty {
                    EmptyView()
                } else if selection != nil {
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label(
                            "Удалить",
                            systemImage: "trash"
                        )
                    }
                    .disabled(selection?.isEmpty != false)
                } else {
                    Button(L10n.text("Выбрать")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = []
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
        .task(id: sessionStore.session?.userID) {
            offlinePlaylists.configure(
                accountID: sessionStore.session?.userID
            )
        }
    }

    private var formattedManualSize: String {
        ByteCountFormatter.string(
            fromByteCount: offlineStore.manualDownloadsByteCount,
            countStyle: .file
        )
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(
            fromByteCount: offlineStore.automaticCacheByteCount,
            countStyle: .file
        )
    }

    @ViewBuilder
    private func downloadRow(for track: Track) -> some View {
        Button {
            if selection != nil {
                toggleSelection(track)
            } else {
                player.play(track, in: offlineStore.downloadedTracks)
            }
        } label: {
            HStack(spacing: 12) {
                if selection != nil {
                    selectionIndicator(for: track)
                }
                AsyncArtwork(url: track.artworkURL, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selection == nil {
                    Image(systemName: "arrow.down.circle.fill")
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

    private var navigationTitle: String {
        guard let selection, !offlineStore.downloadedTracks.isEmpty else {
            return L10n.text("Загрузки")
        }
        return L10n.format("Выбрано: %d", selection.count)
    }

    private func selectionIndicator(for track: Track) -> some View {
        let isSelected = selection?.contains(track.id) == true
        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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

private struct OfflinePlaylistRow: View {
    let record: OfflinePlaylistRecord

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtworkView(
                playlist: record.playlist,
                size: 52,
                showsSource: false
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(record.playlist.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record.state == .downloading || record.state == .queued {
                ProgressView(value: record.progress)
                    .frame(width: 54)
            } else {
                Image(systemName: stateIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        switch record.state {
        case .queued:
            return L10n.text("В очереди")
        case .downloading:
            return L10n.format(
                "%d из %d",
                record.completedCount,
                record.totalCount
            )
        case .available:
            return L10n.trackCount(record.totalCount)
        case .partial:
            return L10n.format(
                "Скачано %d из %d",
                record.completedCount,
                record.totalCount
            )
        case .cancelled:
            return L10n.text("Загрузка отменена")
        case .failed:
            return L10n.text("Не удалось скачать")
        }
    }

    private var stateIcon: String {
        switch record.state {
        case .available:
            return "arrow.down.circle.fill"
        case .partial:
            return "exclamationmark.circle"
        case .cancelled:
            return "xmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .queued, .downloading:
            return "arrow.down.circle"
        }
    }
}

private struct OfflinePlaylistDetailView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    let record: OfflinePlaylistRecord

    var body: some View {
        List(availableTracks) { track in
            Button {
                player.play(track, in: availableTracks)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtwork(url: track.artworkURL, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .foregroundStyle(.primary)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(record.playlist.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var availableTracks: [Track] {
        record.tracks.filter(offlineStore.contains)
    }
}
