import SwiftUI

@main
struct PrivateMusicWatchApp: App {
    @State private var remote = WatchRemoteViewModel()

    var body: some Scene {
        WindowGroup {
            RemotePlayerView()
                .environment(remote)
        }
    }
}
