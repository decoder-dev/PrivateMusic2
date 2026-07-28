import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var model: TrackCollectionViewModel
    @State private var selection = 0

    init() {
        _model = StateObject(
            wrappedValue: TrackCollectionViewModel(
                source: .library
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел медиатеки", selection: $selection) {
                Text("Треки").tag(0)
                Text("Плейлисты").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if selection == 0 {
                TrackCollectionScreen(
                    title: "Моя музыка",
                    emptyMessage: "В медиатеке пока нет треков.",
                    model: model
                )
            } else {
                PlaylistLibraryView()
            }
        }
        .navigationTitle("Моя музыка")
        .task(id: ObjectIdentifier(environment)) {
            await configureAndLoad()
        }
        .refreshable {
            guard selection == 0 else { return }
            guard let token = sessionStore.accessToken else { return }
            await model.load(accessToken: token, force: true)
        }
    }

    private func configureAndLoad() async {
        guard let token = sessionStore.accessToken else { return }
        model.configure(service: environment.musicService)
        await model.load(accessToken: token)
    }
}
