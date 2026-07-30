import SwiftUI

struct OfflineDownloadsView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared

    var body: some View {
        Group {
            if offlineStore.downloadedTracks.isEmpty
                && offlinePlaylists.records.isEmpty {
                EmptyStateView(
                    title: "Нет загрузок",
                    systemImage: "arrow.down.circle",
                    description:
                        "Скачайте треки, чтобы слушать их без интернета."
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
                    Section {
                        ForEach(offlineStore.downloadedTracks) { track in
                            Button {
                                player.play(
                                    track,
                                    in: offlineStore.downloadedTracks
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncArtwork(
                                        url: track.artworkURL,
                                        size: 48
                                    )
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
                                    Image(
                                        systemName: "arrow.down.circle.fill"
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    offlineStore.remove(track)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(
                            L10n.format(
                                "%@ · %@",
                                L10n.trackCount(
                                    offlineStore.downloadedTracks.count
                                ),
                                formattedSize
                            )
                        )
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Загрузки")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionStore.session?.userID) {
            offlinePlaylists.configure(
                accountID: sessionStore.session?.userID
            )
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: offlineStore.totalByteCount,
            countStyle: .file
        )
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
