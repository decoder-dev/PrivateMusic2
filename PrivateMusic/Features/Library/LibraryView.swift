import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var model: TrackCollectionViewModel

    init() {
        _model = StateObject(
            wrappedValue: TrackCollectionViewModel(
                source: .library,
                service: DemoMusicService()
            )
        )
    }

    var body: some View {
        TrackCollectionScreen(
            title: "Моя музыка",
            emptyMessage: "В медиатеке пока нет треков.",
            model: model
        )
        .navigationTitle("Моя музыка")
        .task(id: ObjectIdentifier(environment)) {
            await configureAndLoad()
        }
        .refreshable {
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
