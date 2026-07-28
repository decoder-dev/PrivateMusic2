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
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        settings.theme.colors.last
                            ?? Color(uiColor: .secondarySystemBackground),
                        settings.theme.colors[0]
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if let track = player.currentTrack {
                    ScrollView {
                        VStack(spacing: 24) {
                            AsyncArtwork(url: track.artworkURL, size: 280)
                                .shadow(
                                    color: .black.opacity(0.18),
                                    radius: 24,
                                    y: 12
                                )

                            VStack(spacing: 7) {
                                Text(track.title)
                                    .font(.title2.bold())
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Text(track.artist)
                                    .foregroundStyle(.secondary)
                                if player.isBuffering {
                                    Label(
                                        "Буферизация",
                                        systemImage: "waveform"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 18) {
                                playerAction(
                                    "person.wave.2",
                                    label: "Исполнитель"
                                ) {
                                    showingArtist = true
                                }
                                playerAction(
                                    "quote.bubble",
                                    label: "Текст"
                                ) {
                                    showingLyrics = true
                                }
                                playerAction(
                                    "rectangle.stack.badge.plus",
                                    label: "Добавить в плейлист"
                                ) {
                                    showingPlaylists = true
                                }
                                Button {
                                    Task { await prepareShare(track) }
                                } label: {
                                    if isPreparingShare {
                                        ProgressView()
                                            .frame(width: 42, height: 42)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                            .frame(width: 42, height: 42)
                                            .background(
                                                .thinMaterial,
                                                in: Circle()
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isPreparingShare)
                                .accessibilityLabel("Поделиться")
                            }

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

                            playbackControls
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                } else {
                    EmptyStateView(
                        title: "Плеер",
                        systemImage: "play.circle",
                        description: "Выберите трек в медиатеке, "
                            + "рекомендациях или поиске."
                    )
                    .padding()
                }
            }
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Закрыть") {
                            dismiss()
                        }
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

    private var playbackControls: some View {
        HStack(spacing: 24) {
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
                .font(.system(size: 68))
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(
                        player.repeatMode == .off
                            ? Color.primary
                            : settings.theme.accent
                    )
            }
        }
        .font(.title2)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .adaptiveGlass(in: Capsule(), interactive: true)
    }

    private func playerAction(
        _ image: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
