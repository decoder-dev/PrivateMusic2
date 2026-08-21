import SwiftUI

struct MixFeedbackManagerView: View {
    @Environment(MixFeedbackStore.self) private var mixFeedbackStore
    @State private var showsClearConfirm = false

    var body: some View {
        Form {
            Section {
                if mixFeedbackStore.bannedTracks.isEmpty,
                   mixFeedbackStore.bannedArtistRecords.isEmpty {
                    Text(L10n.text("nothing_is_hidden_yet"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        showsClearConfirm = true
                    } label: {
                        Label(
                            L10n.text("clear_all"),
                            systemImage: "trash"
                        )
                    }
                }
            } footer: {
                Text(
                    L10n.text("hidden_tracks_and_artists_stay_out_of_mixes_on_this_device_vk_has_no_dis")
                )
            }

            if !mixFeedbackStore.bannedTracks.isEmpty {
                Section(L10n.text("hidden_tracks")) {
                    ForEach(mixFeedbackStore.bannedTracks) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !record.artist.isEmpty {
                                    Text(record.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 12)
                            Button(L10n.text("restore")) {
                                mixFeedbackStore.unbanTrack(id: record.id)
                                Haptics.selection()
                            }
                            .font(.subheadline.weight(.semibold))
                            // Without an explicit borderless style the whole
                            // row acts as the button, so tapping a title
                            // silently un-hides the track.
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if !mixFeedbackStore.bannedArtistRecords.isEmpty {
                Section(L10n.text("hidden_artists")) {
                    ForEach(mixFeedbackStore.bannedArtistRecords) { record in
                        HStack {
                            Text(record.displayName)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Button(L10n.text("restore")) {
                                mixFeedbackStore.unbanArtist(key: record.key)
                                Haptics.selection()
                            }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .clearsMiniPlayer(includingWhenDockReservesSpace: true)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("hidden_in_mixes"))
        .confirmationDialog(
            L10n.text("clear_everything_you_hid"),
            isPresented: $showsClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.text("clear"), role: .destructive) {
                mixFeedbackStore.clear()
                Haptics.success()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        }
    }
}
