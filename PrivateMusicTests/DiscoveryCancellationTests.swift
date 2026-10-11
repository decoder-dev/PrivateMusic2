import XCTest
@testable import PrivateMusic

@MainActor
final class DiscoveryCancellationTests: XCTestCase {
    func testCancelledDiscoveryLaunchKeepsMoodAndExistingError() async {
        let environment = AppEnvironment(keychain: KeychainStore(service: UUID().uuidString))
        let originalMood = environment.settings.mixMoodPreference
        defer {
            environment.settings.mixMoodPreference = originalMood
            environment.player.stop()
        }
        environment.mixActionError = "Existing message"
        let differentMood: MixMoodPreference = originalMood == .calm ? .energetic : .calm
        let launch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await environment.startMoodStation(differentMood, in: [])
            await environment.startMixFromArtist(named: "Private Music", seed: nil)
        }
        await launch.value
        XCTAssertEqual(environment.settings.mixMoodPreference, originalMood)
        XCTAssertEqual(environment.mixActionError, "Existing message")
    }
}
