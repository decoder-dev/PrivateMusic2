import XCTest
@testable import PrivateMusic

@MainActor
final class MainTabScrollCoordinatorTests: XCTestCase {
    func testOnlySelectedTabTapIsAReselection() {
        XCTAssertTrue(
            TabReselectionPolicy.isReselection(
                current: "library",
                tapped: "library"
            )
        )
        XCTAssertFalse(
            TabReselectionPolicy.isReselection(
                current: "library",
                tapped: "home"
            )
        )
    }

    func testEachScrollRequestHasFreshIdentity() {
        let coordinator = MainTabScrollCoordinator()

        coordinator.scrollToTop(.library)
        let first = coordinator.request
        coordinator.scrollToTop(.library)
        let second = coordinator.request

        XCTAssertEqual(first?.destination, .library)
        XCTAssertEqual(second?.destination, .library)
        XCTAssertNotEqual(first?.id, second?.id)
    }
}
