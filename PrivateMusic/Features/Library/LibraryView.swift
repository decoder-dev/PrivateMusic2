import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var player: AudioPlayer
    @StateObject private var tracks = TrackCollectionViewModel(source: .library)
    @StateObject private var playlists = PlaylistLibraryViewModel()
    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if playlists.isLoading && playlists.playlists.isEmpty {
                    playlistSkeleton
                } else if !playlists.playlists.isEmpty {
                    playlistShelf
                }

                HStack {
                    Text("Треки")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Text("\(tracks.tracks.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if tracks.isLoading && tracks.tracks.isEmpty {
                    trackSkeleton
                } else if tracks.tracks.isEmpty {
                    EmptyStateView(
                        title: "Медиатека пуста",
                        systemImage: "music.note",
                        description: "Добавленные во VK треки появятся здесь."
                    )
                    .frame(height: 260)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.tracks.enumerated()), id: \.element.id) {
                            index, track in
                            libraryRow(track)
                            if index < tracks.tracks.count - 1 {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .background(ThemeBackground())
        .navigationTitle("Моя музыка")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink {
                    ListeningHistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            PlaylistEditorView(playlist: nil) {
                Task { await load(force: true) }
            }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private var playlistShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Плейлисты")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playlists.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                AsyncArtwork(
                                    url: playlist.artworkURL,
                                    size: 156
                                )
                                Text(playlist.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(playlist.count) треков")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 156, alignment: .leading)
                        }
                        .buttonStyle(PremiumPressStyle())
                    }
                }
            }
        }
    }

    private func libraryRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                player.play(track, in: tracks.tracks)
            } label: {
                HStack(spacing: 12) {
                AsyncArtwork(url: track.artworkURL, size: 52)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button {
                    player.playNext(track)
                } label: {
                    Label("Играть следующим", systemImage: "text.badge.plus")
                }
                Button(role: .destructive) {
                    guard let token = sessionStore.accessToken else { return }
                    Task { await tracks.remove(track, accessToken: token) }
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 44)
            }
        }
        .padding(.vertical, 8)
    }

    private var playlistSkeleton: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.primary.opacity(0.08))
                        .frame(width: 156, height: 190)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private var trackSkeleton: some View {
        VStack(spacing: 14) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(.primary.opacity(0.08))
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.primary.opacity(0.09))
                            .frame(width: 190, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.primary.opacity(0.06))
                            .frame(width: 120, height: 11)
                    }
                    Spacer()
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func load(force: Bool = false) async {
        guard let token = sessionStore.accessToken else { return }
        tracks.configure(service: environment.musicService)
        await tracks.load(accessToken: token, force: force)
        await playlists.load(
            service: environment.musicService,
            accessToken: token,
            force: force
        )
    }
}
