import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        Haptics.open()
                        player.isPlayerPresented = true
                    } label: {
                        HStack(spacing: 10) {
                            AsyncArtwork(url: track.artworkURL, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        player.playPause()
                    } label: {
                        Image(
                            systemName: player.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.headline)
                        .frame(width: 32, height: 40)
                    }

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.headline)
                            .frame(width: 32, height: 40)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tint)
                                .frame(
                                    width: proxy.size.width * progress
                                )
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
            .background(
                settings.theme.surface.opacity(0.98),
                in: RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                )
                .stroke(.primary.opacity(0.13), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
            .frame(height: 58)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .offset(
                x: reduceMotion ? 0 : dragOffset.width * 0.12,
                y: reduceMotion ? 0 : min(dragOffset.height * 0.08, 0)
            )
            .gesture(miniPlayerGesture)
        }
    }

    private var miniPlayerGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(vertical) > abs(horizontal), vertical < -42 {
                    Haptics.open()
                    player.isPlayerPresented = true
                } else if horizontal < -58 {
                    Haptics.trackChange()
                    player.next()
                } else if horizontal > 58 {
                    Haptics.trackChange()
                    player.previous()
                }
            }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(
            min(max(player.elapsedTime / player.duration, 0), 1)
        )
    }
}
