import SwiftUI
import UniformTypeIdentifiers

/// Moves a playlist over from another service: paste "Artist - Title" lines
/// or open a CSV export, let VK search find the songs, check the matches,
/// then create the playlist. Nothing is added to VK before the last tap.
struct PlaylistImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var model = PlaylistImportModel()
    @State private var text = ""
    @State private var playlistName = L10n.text("playlist_import.default_name")
    @State private var choosingFile = false
    @State private var fileError: String?
    @State private var operation: Task<Void, Never>?

    private var items: [PlaylistImportParser.Item] {
        PlaylistImportParser.parse(text)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                switch model.stage {
                case .input:
                    inputSection
                case .matching:
                    progressSection(
                        L10n.format(
                            "playlist_import.searching",
                            model.progress,
                            model.rows.isEmpty ? items.count : model.rows.count
                        )
                    )
                case .review:
                    reviewSection
                case .creating:
                    progressSection(
                        L10n.format(
                            "playlist_import.creating",
                            model.progress,
                            model.rows.filter(\.include).count
                        )
                    )
                case .done(let added, let failed):
                    Section {
                        Label(L10n.text("playlist_import.done_title"), systemImage: "checkmark.circle.fill")
                            .font(.headline)
                        Text(L10n.format("playlist_import.done_detail", added, failed))
                            .foregroundStyle(.secondary)
                    }
                    Button { dismiss() } label: {
                        Text(L10n.text("done")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PremiumProminentButtonStyle())
                    .listRowBackground(Color.clear)
                }
                if let message = model.error ?? fileError {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .background(ThemeBackground())
            .navigationTitle(L10n.text("playlist_import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("action.cancel")) {
                        operation?.cancel()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $choosingFile,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text]
            ) { result in
                switch result {
                case .success(let url): readFile(url)
                case .failure(let failure): fileError = failure.localizedDescription
                }
            }
            .onDisappear { operation?.cancel() }
            .onChange(of: sessionStore.resolvedOfflineAccountID) { _, _ in
                operation?.cancel()
                dismiss()
            }
        }
    }

    // MARK: Input

    private var inputSection: some View {
        Group {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .font(.callout)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button { choosingFile = true } label: {
                    Label(L10n.text("playlist_import.choose_file"), systemImage: "doc.badge.plus")
                }
            } footer: {
                Text(L10n.text("playlist_import.hint"))
            }
            Section {
                Text(
                    items.isEmpty && !text.isEmpty
                        ? L10n.text("playlist_import.nothing_recognized")
                        : L10n.format("playlist_import.recognized", items.count)
                )
                .foregroundStyle(.secondary)
            }
            Button { startSearch() } label: {
                Text(L10n.text("playlist_import.search")).frame(maxWidth: .infinity)
            }
            .buttonStyle(PremiumProminentButtonStyle())
            .listRowBackground(Color.clear)
            .disabled(items.isEmpty)
        }
    }

    private func progressSection(_ title: String) -> some View {
        Section {
            ProgressView(title)
            Button(L10n.text("action.cancel"), role: .cancel) {
                operation?.cancel()
                model.cancelToReview()
            }
        }
    }

    // MARK: Review

    private var reviewSection: some View {
        Group {
            Section {
                ForEach($model.rows) { $row in
                    reviewRow($row)
                }
            } header: {
                Text(
                    L10n.format(
                        "playlist_import.review_summary",
                        model.rows.filter { $0.match != nil }.count,
                        model.rows.count
                    )
                )
            }
            Section {
                TextField(L10n.text("playlist_import.playlist_name"), text: $playlistName)
            }
            Button { create() } label: {
                Text(
                    L10n.format(
                        "playlist_import.create",
                        model.rows.filter(\.include).count
                    )
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PremiumProminentButtonStyle())
            .listRowBackground(Color.clear)
            .disabled(
                model.rows.allSatisfy { !$0.include }
                    || playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    @ViewBuilder
    private func reviewRow(_ row: Binding<PlaylistImportModel.Row>) -> some View {
        if let match = row.wrappedValue.match {
            Toggle(isOn: row.include) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.wrappedValue.item.displayName)
                        .font(.callout)
                        .lineLimit(2)
                    Text("\(match.track.artist) — \(match.track.title)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !match.isConfident {
                        Label(
                            L10n.text("playlist_import.uncertain"),
                            systemImage: "questionmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.wrappedValue.item.displayName)
                    .font(.callout)
                    .lineLimit(2)
                Text(L10n.text("playlist_import.not_found"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Actions

    private func readFile(_ url: URL) {
        fileError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // Exports are UTF-8; a few tools write UTF-16 or Windows-1251.
            guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1251) else {
                fileError = L10n.text("playlist_import.file_unreadable")
                return
            }
            text = content
        } catch {
            fileError = L10n.text("playlist_import.file_unreadable")
        }
    }

    private func startSearch() {
        let found = items
        guard !found.isEmpty else { return }
        fileError = nil
        operation?.cancel()
        operation = Task {
            await model.search(found, environment: environment)
        }
    }

    private func create() {
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let owner = sessionStore.resolvedOfflineAccountID else { return }
        operation?.cancel()
        operation = Task {
            await model.create(title: name, ownerID: owner, environment: environment)
            if case .done = model.stage {
                Haptics.success()
                onCreated()
            }
        }
    }
}

/// Runs the search and creation steps of an import. VK limits requests to a
/// few per second, so the work is sequential and paced.
@MainActor
@Observable
final class PlaylistImportModel {
    struct Row: Identifiable, Equatable {
        let item: PlaylistImportParser.Item
        var match: PlaylistImportMatcher.Match?
        var include: Bool
        var id: String { item.id }
    }

    enum Stage: Equatable {
        case input
        case matching
        case review
        case creating
        case done(added: Int, failed: Int)
    }

    private(set) var stage: Stage = .input
    var rows: [Row] = []
    private(set) var progress = 0
    private(set) var error: String?

    private static let requestSpacing: Duration = .milliseconds(380)
    private static let consecutiveFailureLimit = 5

    func cancelToReview() {
        stage = rows.isEmpty ? .input : .review
    }

    func search(
        _ items: [PlaylistImportParser.Item],
        environment: AppEnvironment
    ) async {
        error = nil
        rows = items.map { Row(item: $0, match: nil, include: false) }
        progress = 0
        stage = .matching
        var failures = 0
        for index in items.indices {
            if Task.isCancelled { return }
            progress = index
            do {
                let page = try await environment.withAuthorizedToken { token in
                    try await environment.musicService.search(
                        query: PlaylistImportMatcher.query(for: items[index]),
                        accessToken: token,
                        offset: 0,
                        count: 10
                    )
                }
                failures = 0
                if let match = PlaylistImportMatcher.best(
                    for: items[index],
                    in: page.items
                ) {
                    rows[index].match = match
                    // Sure matches are on by default; doubtful ones wait for
                    // the user to look at them.
                    rows[index].include = match.isConfident
                }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                if failures >= Self.consecutiveFailureLimit {
                    self.error = error.localizedDescription
                    stage = .review
                    return
                }
            }
            try? await Task.sleep(for: Self.requestSpacing)
        }
        progress = items.count
        if Task.isCancelled { return }
        stage = .review
    }

    func create(
        title: String,
        ownerID: Int,
        environment: AppEnvironment
    ) async {
        let chosen = rows.compactMap { $0.include ? $0.match?.track : nil }
        guard !chosen.isEmpty else { return }
        error = nil
        progress = 0
        stage = .creating
        do {
            let playlist = try await environment.withAuthorizedToken { token in
                try await environment.musicService.createPlaylist(
                    title: title,
                    description: "",
                    ownerID: ownerID,
                    accessToken: token
                )
            }
            var added = 0
            var failed = 0
            for (index, track) in chosen.enumerated() {
                if Task.isCancelled { return }
                progress = index
                do {
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.add(
                            track,
                            to: playlist,
                            accessToken: token
                        )
                    }
                    added += 1
                } catch is CancellationError {
                    return
                } catch {
                    failed += 1
                }
                try? await Task.sleep(for: Self.requestSpacing)
            }
            stage = .done(added: added, failed: failed)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            stage = .review
        }
    }
}
