import SwiftUI

struct OfflineDownloadsView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    @State private var selection: Set<String>?
    @State private var showsDeleteConfirmation = false

    private var allDownloadedTrackIDs: Set<String> {
        Set(offlineStore.records.keys)
    }

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
                    ForEach(
                        playlistSections,
                        id: \.id
                    ) { section in
                        Section {
                            ForEach(section.tracks) { track in
                                trackRow(
                                    track,
                                    playlistTracks: section.allTracks,
                                    inPlaylist: section.id
                                )
                                .transition(.opacity)
                            }
                        } header: {
                            playlistHeader(section)
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
                .animation(.easeInOut(duration: 0.3), value: playlistSections.map(\.id))
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
            offlineStore.configure(
                accountID: sessionStore.session?.userID
            )
        }
    }

    // MARK: - Data

    private struct PlaylistSection: Identifiable {
        let id: String
        let title: String
        let artwork: Playlist?
        var tracks: [Track]
        var allTracks: [Track]
        var record: OfflinePlaylistRecord?
    }

    private var playlistSections: [PlaylistSection] {
        offlinePlaylists.records.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                let downloadedTracks = record.tracks.filter {
                    offlineStore.contains($0)
                }
                return PlaylistSection(
                    id: record.id,
                    title: record.playlist.title,
                    artwork: record.playlist,
                    tracks: downloadedTracks,
                    allTracks: record.tracks,
                    record: record
                )
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
        !playlistSections.isEmpty || !orphanTracks.isEmpty
    }

    // MARK: - Rows

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

    @ViewBuilder
    private func playlistHeader(_ section: PlaylistSection) -> some View {
        if let playlist = section.artwork {
            HStack(spacing: 8) {
                PlaylistArtworkView(
                    playlist: playlist,
                    size: 28,
                    showsSource: false
                )
                Text(section.title)
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                Spacer()
                if let record = section.record,
                   record.state == .downloading
                    || record.state == .queued {
                    AnimatedProgressView(
                        progress: record.progress
                    )
                } else {
                    Text("\(section.tracks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard selection == nil else { return }
            }
        } else {
            Text(section.title)
                .font(.footnote.weight(.semibold))
                .textCase(nil)
        }
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
