import SwiftUI

struct OfflineDownloadsView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var offlineStore: OfflineTrackStore

    var body: some View {
        Group {
            if offlineStore.downloadedTracks.isEmpty {
                EmptyStateView(
                    title: "Нет загрузок",
                    systemImage: "arrow.down.circle",
                    description:
                        "Скачайте треки, чтобы слушать их без интернета."
                )
                .padding()
            } else {
                List {
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
    }

    private var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: offlineStore.totalByteCount,
            countStyle: .file
        )
    }
}
