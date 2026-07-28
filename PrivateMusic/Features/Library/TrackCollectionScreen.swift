import SwiftUI

struct TrackCollectionScreen: View {
    let title: String
    let emptyMessage: String
    @ObservedObject var model: TrackCollectionViewModel

    var body: some View {
        Group {
            if model.isLoading && model.tracks.isEmpty {
                ProgressView("Загружаем музыку…")
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                EmptyStateView(
                    title: "Не удалось загрузить",
                    systemImage: "wifi.exclamationmark",
                    description: error
                )
            } else if model.tracks.isEmpty {
                EmptyStateView(
                    title: title,
                    systemImage: "music.note",
                    description: emptyMessage
                )
            } else {
                List {
                    ForEach(model.tracks) { track in
                        TrackRow(track: track, queue: model.tracks)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Brand.background)
    }
}
