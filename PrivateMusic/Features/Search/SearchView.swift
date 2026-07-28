import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var model = SearchViewModel()

    var body: some View {
        Group {
            if model.query.isEmpty {
                EmptyStateView(
                    title: "Поиск музыки",
                    systemImage: "magnifyingglass",
                    description: "Найдите треки и исполнителей."
                )
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
                List(model.tracks) { track in
                    TrackRow(track: track, queue: model.tracks)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .background(Brand.background)
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
}
