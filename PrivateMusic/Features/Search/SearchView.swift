import SwiftUI

struct SearchView: View {
    private enum Scope: String, CaseIterable {
        case tracks = "Треки"
        case artists = "Исполнители"

        var title: String { L10n.text(rawValue) }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var libraryStore: MusicLibraryStore
    @StateObject private var model = SearchViewModel()
    @State private var scope: Scope = .tracks
    @State private var pendingLibraryTrackIDs = Set<String>()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeBackground())
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.query) { _ in
            scheduleSearch()
        }
        .alert(
            "Не удалось изменить медиатеку",
            isPresented: Binding(
                get: { model.actionErrorMessage != nil },
                set: { if !$0 { model.actionErrorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(model.actionErrorMessage ?? "")
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                L10n.text("Трек или исполнитель"),
                text: $model.query
            )
            .focused($isSearchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                submitSearch()
            }
            .accessibilityLabel("Поисковый запрос")
            .accessibilityHint(
                "Введите не менее двух символов"
            )

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Очистить поиск"))
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 48)
        .background(
            settings.theme.surface,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            searchLanding
        case .needsMoreCharacters:
            SearchStatusView(
                title: "Введите ещё один символ",
                systemImage: "character.cursor.ibeam",
                description: "Для поиска нужно минимум два символа."
            )
        case .loading:
            searchLoading
        case .results:
            searchResults
        case .empty:
            SearchStatusView(
                title: "Ничего не найдено",
                systemImage: "magnifyingglass",
                description: L10n.format(
                    "По запросу «%@» нет результатов.",
                    model.normalizedQuery
                )
            )
        case let .failure(message):
            SearchStatusView(
                title: "Ошибка поиска",
                systemImage: "wifi.exclamationmark",
                description: message,
                actionTitle: "Повторить",
                action: submitSearch
            )
        }
    }

    private var searchLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.text("Найдите музыку"),
                        systemImage: "music.note"
                    )
                    .font(.title2.weight(.bold))
                    Text(
                        L10n.text(
                            "Введите название трека или исполнителя. "
                                + "Результаты появятся автоматически."
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !model.recentQueries.isEmpty {
                    recentQueries
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var recentQueries: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Недавние запросы")
                    .font(.headline)
                Spacer()
                Button("Очистить") {
                    model.clearRecent()
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel(
                    L10n.text("Очистить недавние запросы")
                )
            }
            .padding(.bottom, 4)

            ForEach(model.recentQueries, id: \.self) { query in
                HStack(spacing: 8) {
                    Button {
                        model.useRecent(query)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text(query)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format("Повторить поиск «%@»", query)
                    )

                    Button {
                        model.removeRecent(query)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.format("Удалить запрос «%@»", query)
                    )
                }
                .frame(minHeight: 48)
            }
        }
        .padding(16)
        .premiumCard()
    }

    private var searchLoading: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Ищем в VK…")
                .font(.headline)
            Text(model.normalizedQuery)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Выполняется поиск")
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            Picker("Тип поиска", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let error = model.errorMessage {
                inlineRetry(message: error, action: submitSearch)
            }

            if scope == .tracks {
                trackResults
            } else {
                artistResults
            }
        }
    }

    private var trackResults: some View {
        List {
            ForEach(model.tracks) { track in
                TrackRow(track: track, queue: model.tracks)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if track.id == model.tracks.last?.id {
                            loadMore()
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            add(track)
                        } label: {
                            Label(
                                L10n.text(
                                    libraryStore.contains(track)
                                        ? "Добавлено"
                                        : "В медиатеку"
                                ),
                                systemImage:
                                    libraryStore.contains(track)
                                    ? "checkmark"
                                    : "plus"
                            )
                        }
                        .tint(settings.theme.accent)
                        .disabled(
                            libraryStore.contains(track)
                                || pendingLibraryTrackIDs.contains(track.id)
                        )
                    }
            }

            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView("Загружаем ещё…")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let message = model.paginationErrorMessage {
                inlineRetry(message: message, action: loadMore)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var artistResults: some View {
        List {
            ForEach(model.artists, id: \.self) { artist in
                NavigationLink {
                    ArtistView(artist: artist)
                } label: {
                    Label(artist, systemImage: "person.wave.2")
                }
                .listRowBackground(Color.clear)
                .onAppear {
                    if artist == model.artists.last {
                        loadMore()
                    }
                }
            }

            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView("Загружаем ещё…")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let message = model.paginationErrorMessage {
                inlineRetry(message: message, action: loadMore)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func inlineRetry(
        message: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Повторить", action: action)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }

    private func scheduleSearch() {
        guard sessionStore.accessToken != nil else { return }
        model.schedule(operation: search)
    }

    private func submitSearch() {
        guard sessionStore.accessToken != nil else { return }
        model.submit(operation: search)
    }

    private func search(
        query: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        try await environment.withAuthorizedToken { token in
            try await environment.musicService.search(
                query: query,
                accessToken: token,
                offset: offset,
                count: count
            )
        }
    }

    private func add(_ track: Track) {
        guard sessionStore.accessToken != nil,
              pendingLibraryTrackIDs.insert(track.id).inserted else {
            return
        }
        Task {
            defer { pendingLibraryTrackIDs.remove(track.id) }
            if let added = await model.add(
                track,
                operation: { item in
                    try await environment.withAuthorizedToken { token in
                        try await environment.musicService.addToLibrary(
                            item,
                            accessToken: token
                        )
                    }
                }
            ) {
                libraryStore.markAdded(source: track, stored: added)
            }
        }
    }

    private func loadMore() {
        guard sessionStore.accessToken != nil else { return }
        Task {
            await model.loadMore(operation: search)
        }
    }
}

private struct SearchStatusView: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.title3.weight(.bold))
            Text(L10n.text(description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(L10n.text(actionTitle), action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
