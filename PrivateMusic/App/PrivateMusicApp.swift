import SwiftUI

@main
struct PrivateMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.sessionStore)
                .environmentObject(environment.networkMonitor)
                .environmentObject(environment.historyStore)
                .environmentObject(environment.libraryStore)
                .environmentObject(environment.homeCatalogStore)
                .environmentObject(environment.likedAlbumsStore)
                .environmentObject(environment.offlineStore)
                .environmentObject(environment.player)
        }
    }
}
