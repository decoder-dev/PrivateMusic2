import SwiftUI

struct TrackCollectionScreen: View {
    @Environment(SessionStore.self) private var sessionStore
    let title: String
    let emptyMessage: String
    var model: TrackCollectionViewModel

    var body: some View {
        Group {
            if model.isLoading && model.tracks.isEmpty {
                ProgressView(L10n.text("loading_music"))
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                EmptyStateView(
                    title: "could_not_load",
                    systemImage: "wifi.exclamationmark",
                    description: error,
                    descriptionIsLocalizedKey: false
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
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    guard let token = sessionStore.accessToken
                                    else {
                                        return
                                    }
                                    Task {
                                        await model.remove(
                                            track,
                                            accessToken: token
                                        )
                                    }
                                } label: {
                                    Label(L10n.text("action.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ThemeBackground())
    }
}
