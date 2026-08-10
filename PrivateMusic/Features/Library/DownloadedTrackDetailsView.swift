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

                    Label(
                        "Доступно без интернета",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))

                    VStack(spacing: 0) {
                        detailRow(
                            title: "Формат",
                            value: formatDescription
                        )
                        if let albumTitle = record.track.albumTitle?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           Album.isUsableTitle(albumTitle) {
                            Divider()
                            detailRow(
                                title: "Альбом",
                                value: albumTitle
                            )
                        }
                        Divider()
                        detailRow(
                            title: "Длительность",
                            value: record.track.duration.formattedDuration
                        )
                        Divider()
                        detailRow(
                            title: "Размер",
                            value: ByteCountFormatter.string(
                                fromByteCount: record.byteCount,
                                countStyle: .file
                            )
                        )
                        Divider()
                        detailRow(
                            title: "Сохранено",
                            value: record.downloadedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        Divider()
                        detailRow(
                            title: "Хранение",
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
                            Label(
                                "Воспроизвести",
                                systemImage: "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(localURL == nil)

                        Button {
                            onShare()
                        } label: {
                            Label(
                                "Поделиться аудиофайлом",
                                systemImage: "square.and.arrow.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(localURL == nil)

                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Label(
                                "Удалить с устройства",
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
            .navigationTitle("Аудиофайл")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog(
                "Удалить этот файл с устройства?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
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
                "Потоковое аудио · при отправке создаётся M4A"
            )
        case .directFile:
            let ext = localURL?.pathExtension.uppercased() ?? "AUDIO"
            return ext.isEmpty ? "AUDIO" : ext
        }
    }

    private var retentionDescription: String {
        switch record.resolvedRetention {
        case .manual:
            return L10n.text("Сохранено вручную")
        case .automaticCache:
            return L10n.text("Автокэш — может очищаться автоматически")
        }
    }
}
