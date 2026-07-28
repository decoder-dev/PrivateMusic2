import SwiftUI

struct SearchView: View {
    private enum Scope: String, CaseIterable {
        case tracks = "Треки"
        case artists = "Исполнители"
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = SearchViewModel()
    @State private var scope: Scope = .tracks

    var body: some View {
        Group {
            if model.query.isEmpty {
                searchLanding
            } else if model.isLoading && model.tracks.isEmpty {
                ProgressView()
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                EmptyStateView(
                    title: "Ошибка поиска",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.tracks.isEmpty {
                EmptyStateView(
                    title: "Ничего не найдено",
                    systemImage: "magnifyingglass",
                    description: "По запросу «\(model.query)» нет результатов."
                )
            } else {
                VStack(spacing: 0) {
                    Picker("Тип поиска", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    if scope == .tracks {
                        List(model.tracks) { track in
                            TrackRow(track: track, queue: model.tracks)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        add(track)
                                    } label: {
                                        Label(
                                            "В медиатеку",
                                            systemImage: "plus"
                                        )
                                    }
                                    .tint(settings.theme.accent)
                                }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    } else {
                        List(model.artists, id: \.self) { artist in
                            NavigationLink {
                                ArtistView(artist: artist)
                            } label: {
                                Label(
                                    artist,
                                    systemImage: "person.wave.2"
                                )
                            }
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                }
                }
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Поиск")
        .searchable(text: $model.query, prompt: "Треки и исполнители")
        .onChange(of: model.query) { _ in
            guard let token = sessionStore.accessToken else { return }
            model.schedule(
                service: environment.musicService,
                accessToken: token
            )
        }
    }

    private var searchLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Вся музыка VK")
                        .font(.largeTitle.weight(.heavy))
                    Text("Треки и исполнители в одном поиске")
                        .foregroundStyle(.secondary)
                }

                if !model.recentQueries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Недавние запросы")
                                .font(.title3.bold())
                            Spacer()
                            Button("Очистить") { model.clearRecent() }
                                .font(.caption)
                        }
                        ForEach(model.recentQueries, id: \.self) { query in
                            HStack(spacing: 12) {
                                Button {
                                    model.useRecent(query)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                        Text(query)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button {
                                    model.removeRecent(query)
                                } label: {
                                    Image(systemName: "xmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(18)
                    .premiumCard()
                }
            }
            .padding()
        }
    }

    private func add(_ track: Track) {
        guard let token = sessionStore.accessToken else { return }
        Task {
            await model.add(
                track,
                service: environment.musicService,
                accessToken: token
            )
        }
    }
}
