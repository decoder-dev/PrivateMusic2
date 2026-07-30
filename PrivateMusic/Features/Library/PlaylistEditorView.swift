import SwiftUI

struct PlaylistEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
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
                Section("Плейлист") {
                    TextField("Название", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField(
                        "Описание",
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
                    playlist == nil ? "Новый плейлист" : "Редактирование"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        L10n.text(isSaving ? "Сохраняем…" : "Сохранить")
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
        .alert(
            "Не удалось сохранить",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        guard let token = sessionStore.accessToken else { return }
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isSaving = true
        defer { isSaving = false }
        do {
            if let playlist {
                try await environment.musicService.editPlaylist(
                    playlist,
                    title: cleanTitle,
                    description: description,
                    accessToken: token
                )
            } else {
                guard let ownerID = sessionStore.session?.userID
                    ?? sessionStore.profile?.id else {
                    throw APIError.invalidResponse
                }
                _ = try await environment.musicService.createPlaylist(
                    title: cleanTitle,
                    description: description,
                    ownerID: ownerID,
                    accessToken: token
                )
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
