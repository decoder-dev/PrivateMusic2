import XCTest
@testable import PrivateMusic

final class QueueContextTitlePolicyTests: XCTestCase {
    func testAlbumSourceUsesItsTitle() {
        XCTAssertEqual(
            QueueContextTitlePolicy.resolve(
                queueSource: .album(title: "Release"),
                queueSeedTrackTitle: nil
            ),
            "Release"
        )
    }

    func testImplicitQueueFallsBackToSeedTrack() {
        XCTAssertEqual(
            QueueContextTitlePolicy.resolve(
                queueSource: nil,
                queueSeedTrackTitle: "Seed"
            ),
            L10n.format("mix_based_on_0", "Seed")
        )
    }
}
