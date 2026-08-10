import SwiftUI
import Foundation

struct TrackRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Rows deliberately do not observe `AudioPlayer`: its buffering /
    /// duration / shuffle updates would invalidate every visible cell.
    /// Identity + play state come from `highlight`, actions go through
    /// `environment.player`.
    @EnvironmentObject private var highlight: PlaybackHighlightModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @EnvironmentObject private var mixFeedbackStore: MixFeedbackStore
    let track: Track
    let queue: [Track]
    var source: QueueSource? = nil
    @State private var sharingTrack: Track?

    var body: some View {
        Button {
            Haptics.selection()
            environment.player.play(track, in: queue, source: source)
        } label: {
            HStack(spacing: 12) {
                AsyncArtwork(url: track.artworkURL, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    if let title = usableMetadata(track.title) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                isCurrent
                                    ? currentTrackColor
                                    : Color.primary
                            )
                            .lineLimit(1)
                    }
                    if let artist = usableMetadata(track.artist) {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if OfflineDownloadsFeature.showsControls,
                   !environment.isShareSessionActive {
                    if offlineStore.contains(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                L10n.text("Доступно офлайн")
                            )
                    } else if offlineStore.downloadingTrackIDs
                        .contains(track.id) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Загрузка"))
                    }
                }

                LikedTrackBadge(track: track)

                Text(track.duration.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Group {
                    if isCurrent {
                        PlaybackIndicatorView(
                            isPlaying: highlight.isPlaying,
                            color: currentTrackColor
                        )
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                    .font(.caption)
                    .foregroundStyle(
                        isCurrent
                            ? currentTrackColor
                            : Color.secondary
                    )
                    .frame(width: 22, height: 22)
                    .adaptiveGlass(in: Circle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .modifier(CurrentTrackAccessibilityValueModifier(isCurrent: isCurrent))
        .accessibilityHint(L10n.text("Воспроизвести трек"))
        .trackShareSheet(track: $sharingTrack)
        .contextMenu {
            Button {
                environment.player.playNext(track)
            } label: {
                Label(
                    "Играть следующим",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            Button {
                Haptics.open()
                environment.player.play(track, in: queue, source: source)
                environment.player.presentPlayer()
            } label: {
                Label("Открыть плеер", systemImage: "play.circle")
            }
            TrackMixActions.menuButtons(
                for: track,
                environment: environment,
                includeDislike: !mixFeedbackStore.isBanned(track)
            )
            Button {
                Haptics.open()
                sharingTrack = track
            } label: {
                Label(
                    "Поделиться аудиофайлом",
                    systemImage: "square.and.arrow.up"
                )
            }
            if OfflineDownloadsFeature.showsControls,
               !environment.isShareSessionActive {
                Button(
                    role: offlineStore.contains(track) ? .destructive : nil
                ) {
                    toggleOffline()
                } label: {
                    Label(
                        offlineStore.contains(track)
                            ? "Удалить загрузку"
                            : "Скачать офлайн",
                        systemImage: offlineStore.contains(track)
                            ? "trash"
                            : "arrow.down.circle"
                    )
                }
                .disabled(
                    offlineStore.downloadingTrackIDs.contains(track.id)
                )
            }
        }
    }

    private var isCurrent: Bool {
        highlight.isCurrent(track.id)
    }

    private var currentTrackColor: Color {
        settings.theme == .dark
            ? settings.theme.accent
            : .black
    }

    private var accessibilityLabel: String {
        let metadata = [
            usableMetadata(track.title),
            usableMetadata(track.artist)
        ]
            .compactMap { $0 }
            .joined(separator: " — ")
        guard !metadata.isEmpty else { return spokenDuration }
        return L10n.format("%@, %@", metadata, spokenDuration)
    }

    private var spokenDuration: String {
        guard track.duration.isFinite, track.duration >= 0 else {
            return L10n.seconds(0)
        }
        let total = Int(track.duration)
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 {
            return L10n.seconds(seconds)
        }
        if seconds == 0 {
            return L10n.minutes(minutes)
        }
        return L10n.format(
            "%@ %@",
            L10n.minutes(minutes),
            L10n.seconds(seconds)
        )
    }

    private func toggleOffline() {
        Task {
            do {
                if offlineStore.contains(track) {
                    offlineStore.remove(track)
                } else {
                    try await environment.downloadForOffline(track)
                }
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                environment.player.errorMessage = L10n.format(
                    "Не удалось сохранить трек офлайн: %@",
                    error.localizedDescription
                )
            }
        }
    }

    private func usableMetadata(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CurrentTrackAccessibilityValueModifier: ViewModifier {
    let isCurrent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCurrent {
            content.accessibilityValue(L10n.text("Сейчас играет"))
        } else {
            content
        }
    }
}

extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
