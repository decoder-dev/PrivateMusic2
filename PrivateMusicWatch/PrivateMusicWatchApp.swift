import SwiftUI

@main
struct PrivateMusicWatchApp: App {
    @StateObject private var remote = WatchRemoteViewModel()

    var body: some Scene {
        WindowGroup {
            RemotePlayerView()
                .environmentObject(remote)
        }
    }
}
