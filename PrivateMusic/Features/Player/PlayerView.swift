import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingArtist = false
    @State private var showingPlaylists = false
    @State private var shareFileURL: URL?
    @State private var isPreparingShare = false
    private let shareService = TrackShareService()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        settings.theme.secondaryAccent.opacity(0.46),
                        settings.theme.colors[0]
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if let track = player.currentTrack {
                    VStack(spacing: 28) {
                        Spacer()
                        AsyncArtwork(url: track.artworkURL, size: 310)
                            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)

                        VStack(spacing: 7) {
                            Text(track.title)
                                .font(.title2.bold())
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(track.artist)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 14) {
                            Button {
                                showingArtist = true
                            } label: {
                                Label(
                                    "Исполнитель",
                                    systemImage: "person.wave.2"
                                )
                            }
                            Button {
                                showingLyrics = true
                            } label: {
                                Label(
                                    "Текст",
                                    systemImage: "quote.bubble"
                                )
                            }
                            .disabled(track.lyricsID == nil)
                            Button {
                                showingPlaylists = true
                            } label: {
                                Image(
                                    systemName:
                                        "rectangle.stack.badge.plus"
                                )
                                .accessibilityLabel(
                                    "Добавить в плейлист"
                                )
                            }
                            Button {
                                Task { await prepareShare(track) }
                            } label: {
                                if isPreparingShare {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .disabled(isPreparingShare)
                        }
                        .font(.subheadline)
                        .buttonStyle(.bordered)

                        VStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { player.elapsedTime },
                                    set: { player.seek(to: $0) }
                                ),
                                in: 0...max(player.duration, 1)
                            )
                            HStack {
                                Text(player.elapsedTime.formattedDuration)
                                Spacer()
                                Text(player.duration.formattedDuration)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 27) {
                            Button {
                                player.toggleShuffle()
                            } label: {
                                Image(systemName: "shuffle")
                                    .foregroundStyle(
                                        player.shuffleEnabled
                                            ? settings.theme.accent
                                            : Color.primary
                                    )
                            }
                            Button {
                                player.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                            }
                            Button {
                                player.playPause()
                            } label: {
                                Image(
                                    systemName: player.isPlaying
                                        ? "pause.circle.fill"
                                        : "play.circle.fill"
                                )
                                .font(.system(size: 72))
                            }
                            Button {
                                player.next()
                            } label: {
                                Image(systemName: "forward.fill")
                            }
                            Button {
                                player.cycleRepeatMode()
                            } label: {
                                Image(
                                    systemName: player.repeatMode.systemImage
                                )
                                .foregroundStyle(
                                    player.repeatMode == .off
                                        ? Color.primary
                                        : settings.theme.accent
                                )
                            }
                        }
                        .font(.title)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .adaptiveGlass(
                            in: Capsule(),
                            interactive: true
                        )

                        Spacer()
                    }
                    .padding(.horizontal, 26)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQueue = true
                    } label: {
                        Image(
                            systemName:
                                "text.line.first.and.arrowtriangle.forward"
                        )
                    }
                }
            }
        }
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
        .sheet(
            isPresented: Binding(
                get: { shareFileURL != nil },
                set: {
                    if !$0 {
                        shareFileURL = nil
                    }
                }
            )
        ) {
            if let shareFileURL {
                TrackShareSheet(fileURL: shareFileURL)
            }
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
}
