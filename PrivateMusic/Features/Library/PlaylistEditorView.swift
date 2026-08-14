import SwiftUI

struct PlaylistEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist?
    let onSaved: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(playlist: Playlist?, onSaved: @escaping () -> Void) {
        self.playlist = playlist
        self.onSaved = onSaved
        _title = State(initialValue: playlist?.title ?? "")
        _description = State(initialValue: playlist?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("playlist")) {
                    TextField(L10n.text("title"), text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField(L10n.text("description"),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeBackground())
            .navigationTitle(
                L10n.text(
                    playlist == nil ? "new_playlist" : "edit_playlist"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("action.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        L10n.text(isSaving ? "saving" : "action.save")
                    ) {
                        Task { await save() }
                    }
                    .disabled(
                        isSaving
                            || title.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
        }
        .alert(L10n.text("could_not_save"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isSaving = true
        defer { isSaving = false }
        do {
            if let playlist {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.editPlaylist(
                        playlist,
                        title: cleanTitle,
                        description: description,
                        accessToken: token
                    )
                }
            } else {
                guard let ownerID = sessionStore.session?.userID
                    ?? sessionStore.profile?.id else {
                    throw APIError.invalidResponse
                }
                _ = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.createPlaylist(
                        title: cleanTitle,
                        description: description,
                        ownerID: ownerID,
                        accessToken: token
                    )
                }
            }
            onSaved()
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
