import SwiftUI

@main
struct PrivateMusicApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.sessionStore)
                .environmentObject(environment.player)
        }
    }
}
