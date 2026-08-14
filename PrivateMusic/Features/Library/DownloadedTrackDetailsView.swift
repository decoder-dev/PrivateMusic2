import SwiftUI

struct DownloadedTrackDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let record: OfflineTrackRecord
    let localURL: URL?
    let onPlay: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    @State private var showsDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AsyncArtwork(
                        url: record.track.artworkURL,
                        size: 132
                    )
                    .overlay(alignment: .topTrailing) {
                        LikedTrackBadge(
                            track: record.track,
                            style: .artwork
                        )
                        .padding(8)
                    }

                    VStack(spacing: 5) {
                        Text(record.track.title)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(record.track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Label(L10n.text("available_offline_2"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))

                    VStack(spacing: 0) {
                        detailRow(
                            title: "format",
                            value: formatDescription
                        )
                        if let albumTitle = record.track.albumTitle?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           Album.isUsableTitle(albumTitle) {
                            Divider()
                            detailRow(
                                title: "album",
                                value: albumTitle
                            )
                        }
                        Divider()
                        detailRow(
                            title: "duration",
                            value: record.track.duration.formattedDuration
                        )
                        Divider()
                        detailRow(
                            title: "size",
                            value: ByteCountFormatter.string(
                                fromByteCount: record.byteCount,
                                countStyle: .file
                            )
                        )
                        Divider()
                        detailRow(
                            title: "saved",
                            value: record.downloadedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        Divider()
                        detailRow(
                            title: "storage",
                            value: retentionDescription
                        )
                    }
                    .padding(.horizontal, 16)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous
                        )
                    )

                    VStack(spacing: 12) {
                        Button {
                            onPlay()
                            dismiss()
                        } label: {
                            Label(L10n.text("play"),
                                systemImage: "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(localURL == nil)

                        Button {
                            onShare()
                        } label: {
                            Label(L10n.text("share_audio_file"),
                                systemImage: "square.and.arrow.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(localURL == nil)

                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Label(L10n.text("remove_from_device"),
                                systemImage: "trash"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(24)
            }
            .background(ThemeBackground())
            .navigationTitle(L10n.text("audio_file"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("done")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.text("delete_this_file_from_the_device"),
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.text("action.delete"), role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button(L10n.text("action.cancel"), role: .cancel) {}
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func detailRow(
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 13)
    }

    private var formatDescription: String {
        switch record.resolvedStorage {
        case .hlsPackage:
            return L10n.text(
                "streaming_audio_m4a_is_created_on_share"
            )
        case .directFile:
            let ext = localURL?.pathExtension.uppercased() ?? "AUDIO"
            return ext.isEmpty ? "AUDIO" : ext
        }
    }

    private var retentionDescription: String {
        switch record.resolvedRetention {
        case .manual:
            return L10n.text("saved_manually")
        case .automaticCache:
            return L10n.text("auto_cache_may_be_cleared_automatically")
        }
    }
}
