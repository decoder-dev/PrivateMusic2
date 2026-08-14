import Foundation
import SwiftUI

struct RemotePlayerView: View {
    @Environment(WatchRemoteViewModel.self) private var remote

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

                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    progress(at: timeline.date)
                }

                controls

                if remote.commandFailed {
                    Label(
                        WatchL10n.text("command_failed"),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                } else if !remote.isReachable {
                    Label(
                        WatchL10n.text("iphone_unavailable"),
                        systemImage: "iphone.slash"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                queueList
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
        .accessibilityHidden(true)
    }

    private func progress(at date: Date) -> some View {
        let elapsed = remote.state.displayedElapsed(at: date)
        return VStack(spacing: 3) {
            if remote.state.duration > 0 {
                ProgressView(
                    value: elapsed,
                    total: remote.state.duration
                )
                .tint(.white)
                .accessibilityLabel(WatchL10n.text("playback_progress"))
                .accessibilityValue(
                    "\(format(elapsed)) / \(format(remote.state.duration))"
                )
                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text("-\(format(max(0, remote.state.duration - elapsed)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .accessibilityLabel(WatchL10n.text("loading"))
            }
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if remote.state.isMixQueue {
                Text(WatchL10n.text("mix_queue"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 16) {
                Button {
                    remote.send(.previous)
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WatchL10n.text("previous_track"))

                Button {
                    remote.send(.togglePlayPause)
                } label: {
                    ZStack {
                        Image(
                            systemName: remote.state.isPlaying
                                ? "pause.circle.fill"
                                : "play.circle.fill"
                        )
                        .font(.system(size: 42))
                        if remote.state.isBuffering {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    WatchL10n.text(
                        remote.state.isPlaying ? "pause" : "play"
                    )
                )

                Button {
                    remote.send(.next)
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WatchL10n.text("next_track"))
            }
            .font(.title3)
            .padding(.vertical, 4)

            Button {
                remote.send(
                    remote.state.isLiked ? .unlikeCurrent : .likeCurrent
                )
            } label: {
                Label(
                    WatchL10n.text(
                        remote.state.isLiked ? "unlike_track" : "like_track"
                    ),
                    systemImage: remote.state.isLiked
                        ? "heart.fill"
                        : "heart"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(remote.state.isLiked ? .pink : .white)
        }
        .disabled(!remote.isReachable || remote.state.isBuffering)
        .opacity(remote.isReachable ? 1 : 0.45)
    }

    private var queueList: some View {
        let items = remote.state.queue
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(WatchL10n.text("queue"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(
                        Array(items.enumerated()),
                        id: \.offset
                    ) { index, item in
                        let isCurrent = index == remote.state.currentQueueIndex
                        Button {
                            remote.send(
                                .playQueueItem,
                                trackID: item.trackID
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                if isCurrent {
                                    Text(WatchL10n.text("now_playing_row"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.title)
                                    .font(
                                        .caption.weight(
                                            isCurrent ? .semibold : .regular
                                        )
                                    )
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent || !remote.isReachable)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 36))
            Text(WatchL10n.text("open_on_iphone"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(WatchL10n.text("start_track_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#Preview {
    RemotePlayerView()
        .environment(WatchRemoteViewModel())
}
