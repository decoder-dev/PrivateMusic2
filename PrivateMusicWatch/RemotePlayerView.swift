import SwiftUI

struct RemotePlayerView: View {
    @EnvironmentObject private var remote: WatchRemoteViewModel

    var body: some View {
        Group {
            if remote.state.trackID == nil {
                emptyState
            } else {
                player
            }
        }
        .containerBackground(.black.gradient, for: .navigation)
    }

    private var player: some View {
        ScrollView {
            VStack(spacing: 8) {
                artwork

                Text(remote.state.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(remote.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(
                    value: min(remote.state.elapsed, remote.state.duration),
                    total: max(remote.state.duration, 1)
                )
                .tint(.white)
                .padding(.horizontal, 4)

                controls

                if !remote.isReachable {
                    Label("iPhone не в сети", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var artwork: some View {
        AsyncImage(url: remote.state.artworkURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                remote.send(.previous)
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button {
                remote.send(.togglePlayPause)
            } label: {
                Image(
                    systemName: remote.state.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: 42))
            }
            .buttonStyle(.plain)

            Button {
                remote.send(.next)
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 36))
            Text("Откройте Private Music на iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Запустите трек — он появится здесь.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    RemotePlayerView()
        .environmentObject(WatchRemoteViewModel())
}
