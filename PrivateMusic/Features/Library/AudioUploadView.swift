import SwiftUI
import UniformTypeIdentifiers

struct AudioUploadView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    let onUploaded: () -> Void
    @State private var artist = ""
    @State private var title = ""
    @State private var file: URL?
    @State private var filename = ""
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { choosing = true } label: {
                        Label(filename.isEmpty ? L10n.text("features.upload.choose") : filename, systemImage: "doc.badge.plus")
                    }.disabled(busy)
                    TextField(L10n.text("features.upload.artist"), text: $artist).disabled(busy)
                    TextField(L10n.text("title"), text: $title).disabled(busy)
                } footer: { Text(L10n.text("features.upload.hint")) }
                if busy { ProgressView(L10n.text("features.upload.progress")) }
                if let error { Text(error).foregroundStyle(.secondary) }
                Button(L10n.text("features.upload.submit")) { upload() }
                    .disabled(busy || file == nil || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(L10n.text("features.upload.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("action.cancel")) { operation?.cancel(); dismiss() }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.mp3]) { result in
                switch result {
                case let .success(url): importFile(url)
                case let .failure(failure): error = failure.localizedDescription
                }
            }
            .onDisappear {
                operation?.cancel()
                if let file { try? FileManager.default.removeItem(at: file) }
            }
            .onChange(of: sessionStore.resolvedOfflineAccountID) { _, _ in operation?.cancel(); dismiss() }
        }
    }

    private func importFile(_ url: URL) {
        busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do {
                let staged = try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= VKUploadPolicy.maximumAudioBytes else {
                        throw APIError.server(code: 0, message: L10n.text("features.upload.size"))
                    }
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
                    try FileManager.default.copyItem(at: url, to: copy)
                    return copy
                }.value
                if Task.isCancelled { try? FileManager.default.removeItem(at: staged); return }
                if let file { try? FileManager.default.removeItem(at: file) }
                file = staged; filename = url.lastPathComponent
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func upload() {
        guard !busy, let file else { return }
        busy = true; error = nil
        let owner = sessionStore.resolvedOfflineAccountID
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = Task {
            defer { busy = false }
            do {
                _ = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.uploadAudio(file: file, artist: cleanArtist,
                        title: cleanTitle, accessToken: token)
                }
                try Task.checkCancellation()
                guard owner == sessionStore.resolvedOfflineAccountID else { return }
                onUploaded(); dismiss()
            } catch {
                if !Task.isCancelled { self.error = L10n.text("features.upload.failure") + "\n" + error.localizedDescription }
            }
        }
    }
}
