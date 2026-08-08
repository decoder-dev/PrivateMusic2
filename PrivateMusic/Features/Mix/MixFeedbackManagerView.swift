import SwiftUI

struct MixFeedbackManagerView: View {
    @EnvironmentObject private var mixFeedbackStore: MixFeedbackStore
    @State private var showsClearConfirm = false

    var body: some View {
        Form {
            Section {
                if mixFeedbackStore.bannedTracks.isEmpty,
                   mixFeedbackStore.bannedArtistRecords.isEmpty {
                    Text(L10n.text("Пока ничего не скрыто"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        showsClearConfirm = true
                    } label: {
                        Label(
                            L10n.text("Очистить всё"),
                            systemImage: "trash"
                        )
                    }
                }
            } footer: {
                Text(
                    L10n.text(
                        "Скрытые треки и исполнители не попадают в миксы "
                            + "на этом устройстве. VK API для дизлайков нет — "
                            + "память локальная."
                    )
                )
            }

            if !mixFeedbackStore.bannedTracks.isEmpty {
                Section(L10n.text("Скрытые треки")) {
                    ForEach(mixFeedbackStore.bannedTracks) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title)
                                    .font(.body.weight(.semibold))
                                if !record.artist.isEmpty {
                                    Text(record.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(L10n.text("Вернуть")) {
                                mixFeedbackStore.unbanTrack(id: record.id)
                                Haptics.selection()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }

            if !mixFeedbackStore.bannedArtistRecords.isEmpty {
                Section(L10n.text("Скрытые исполнители")) {
                    ForEach(mixFeedbackStore.bannedArtistRecords) { record in
                        HStack {
                            Text(record.displayName)
                            Spacer()
                            Button(L10n.text("Вернуть")) {
                                mixFeedbackStore.unbanArtist(key: record.key)
                                Haptics.selection()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("Скрытое в миксах"))
        .confirmationDialog(
            L10n.text("Очистить все скрытия?"),
            isPresented: $showsClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Очистить"), role: .destructive) {
                mixFeedbackStore.clear()
                Haptics.success()
            }
            Button(L10n.text("Отмена"), role: .cancel) {}
        }
    }
}
