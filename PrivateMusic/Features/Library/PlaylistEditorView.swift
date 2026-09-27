import SwiftUI
import PhotosUI
import ImageIO

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
    @State private var isHidden: Bool
    @State private var savedHidden: Bool
    @State private var savedPlaylist: Playlist?
    @State private var selection: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var loadingPhoto = false
    @State private var saveTask: Task<Void, Never>?


    init(playlist: Playlist?, onSaved: @escaping () -> Void) {
        self.playlist = playlist
        self.onSaved = onSaved
        _isHidden = State(initialValue: playlist?.isHidden ?? false)
        _savedHidden = State(initialValue: playlist?.isHidden ?? false)
        _savedPlaylist = State(initialValue: playlist)
        _title = State(initialValue: playlist?.title ?? "")
        _description = State(initialValue: playlist?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let coverData, let image = UIImage(data: coverData) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxHeight: 180).frame(maxWidth: .infinity).accessibilityHidden(true)
                    } else if let playlist = savedPlaylist {
                        PlaylistArtworkView(playlist: playlist, size: 120)
                            .frame(maxWidth: .infinity)
                    }
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(L10n.text("features.playlist.cover"), systemImage: "photo.badge.plus")
                    }.disabled(isSaving)
                    if loadingPhoto { ProgressView() }
                }
                Section(L10n.text("playlist")) {
                    TextField(L10n.text("title"), text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField(L10n.text("description"),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }.disabled(isSaving)
                Section {
                    Toggle(L10n.text("features.playlist.hidden"), isOn: $isHidden).disabled(isSaving)
                } footer: {
                    Text(L10n.text("features.playlist.hidden_hint"))
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
                        saveTask = Task { await save() }
                    }
                    .disabled(
                        isSaving || loadingPhoto
                            || title.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onDisappear { saveTask?.cancel() }
        .onChange(of: sessionStore.resolvedOfflineAccountID) { _, _ in saveTask?.cancel(); dismiss() }
        .task(id: selection) { await prepareCover() }
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

    private func prepareCover() async {
        guard let selection else { return }
        loadingPhoto = true
        defer { if self.selection == selection { loadingPhoto = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self), data.count <= 50_000_000 else {
                throw APIError.invalidResponse
            }
            let jpeg = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200
                      ] as CFDictionary),
                      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
                    throw APIError.invalidResponse
                }
                return jpeg
            }.value
            try Task.checkCancellation()
            coverData = jpeg
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = sessionStore.resolvedOfflineAccountID
        isSaving = true
        defer { isSaving = false }
        var metadataSaved = false
        do {
            let target: Playlist
            if let existing = savedPlaylist {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.editPlaylist(existing, title: cleanTitle,
                        description: description, accessToken: token)
                }
                target = existing
            } else {
                guard let ownerID = account else { throw APIError.unauthorized }
                target = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.createPlaylist(title: cleanTitle, description: description,
                        ownerID: ownerID, hidden: isHidden, accessToken: token)
                }
                savedPlaylist = target
                savedHidden = isHidden
            }
            metadataSaved = true
            try Task.checkCancellation()
            guard account == sessionStore.resolvedOfflineAccountID else { throw CancellationError() }
            if isHidden != savedHidden {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.setPlaylistHidden(target, hidden: isHidden, accessToken: token)
                }
                savedHidden = isHidden
            }
            try Task.checkCancellation()
            guard account == sessionStore.resolvedOfflineAccountID else { throw CancellationError() }
            if let coverData {
                try await environment.withAuthorizedToken { token in
                    try await environment.musicService.setPlaylistCover(target, jpeg: coverData, accessToken: token)
                }
                self.coverData = nil
            }
            try Task.checkCancellation()
            guard account == sessionStore.resolvedOfflineAccountID else { return }
            onSaved(); dismiss()
        } catch is CancellationError {
        } catch {
            errorMessage = (metadataSaved ? L10n.text("features.playlist.partial") + "\n" : "") + error.localizedDescription
            if metadataSaved { onSaved() }
        }
    }
}
