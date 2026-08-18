import SwiftUI

@main
struct PrivateMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.settings)
                .environment(environment.sessionStore)
                .environment(environment.networkMonitor)
                .environment(environment.historyStore)
                .environment(environment.libraryStore)
                .environment(environment.homeCatalogStore)
                .environment(environment.likedAlbumsStore)
                .environment(environment.offlineStore)
                .environment(environment.pinnedMixStore)
                .environment(environment.mixFeedbackStore)
                .environment(environment.homePersonalizationStore)
                .environment(environment.player)
                .environment(environment.player.progress)
                .environment(environment.player.highlight)
        }
    }
}
