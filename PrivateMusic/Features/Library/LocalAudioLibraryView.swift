import SwiftUI
import UniformTypeIdentifiers

struct LocalAudioLibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var choosing = false
    @State private var importTask: Task<Void, Never>?
    @State private var pendingRemoval: LocalAudioEntry?

    private var library: LocalAudioLibrary { environment.localAudioLibrary }
    private var visible: [LocalAudioEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.entries.filter {
            search.isEmpty || [$0.title, $0.artist, $0.album ?? ""].contains { $0.localizedStandardContains(search) }
        }
    }

    var body: some View {
        let displayed = visible
        let queue = displayed.map { $0.track(in: library.directory) }
        List {
            Section {
                Text(L10n.text("local_audio.description"))
                    .font(.subheadline).foregroundStyle(.secondary)
                if library.isImporting {
                    ProgressView(L10n.text("local_audio.importing"))
                }
                if let error = library.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(settings.surfaceColor)
            if library.entries.isEmpty, !library.isImporting {
                Section {
                    EmptyStateView(title: "local_audio.empty", systemImage: "music.note",
                                   description: "local_audio.empty_hint")
                    Button(L10n.text("local_audio.import")) { choosing = true }
                        .buttonStyle(PremiumProminentButtonStyle())
                }
                .listRowBackground(settings.surfaceColor)
            } else {
                Section(L10n.trackCount(displayed.count)) {
                    ForEach(displayed) { entry in
                        TrackRow(track: entry.track(in: library.directory), queue: queue,
                                 source: .localFiles, allowsContinuation: false,
                                 showsOfflineState: false, showsLikedBadge: false)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingRemoval = entry } label: {
                                    Label(L10n.text("action.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
                .listRowBackground(settings.surfaceColor)
                if displayed.isEmpty {
                    Text(L10n.text("no_results")).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("local_audio.title"))
        .searchable(text: $query, prompt: L10n.text("track_or_artist"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { choosing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("local_audio.import"))
                    .disabled(library.isImporting)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): importTask = Task { await library.importFiles(urls) }
            case let .failure(error): library.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(L10n.text("local_audio.remove_title"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let pendingRemoval {
                Button(L10n.text("action.delete"), role: .destructive) { remove(pendingRemoval) }
            }
        } message: { Text(L10n.text("local_audio.remove_hint")) }
        .onDisappear { importTask?.cancel() }
    }

    private func remove(_ entry: LocalAudioEntry) {
        pendingRemoval = nil
        Task {
            do {
                let id = entry.track(in: library.directory).id
                for index in environment.player.queue.indices.reversed() where environment.player.queue[index].id == id {
                    environment.player.removeFromQueue(at: index)
                }
                try await library.remove(entry)
            } catch { library.errorMessage = error.localizedDescription }
        }
    }
}
