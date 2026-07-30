import XCTest
@testable import PrivateMusic

final class PlayerLayoutMetricsTests: XCTestCase {
    func testActionPanelUsesCompactMaximumWidth() {
        XCTAssertEqual(
            PlayerLayoutMetrics.actionPanelWidth(
                containerWidth: 393,
                safeLeading: 0,
                safeTrailing: 0
            ),
            224
        )
    }

    func testActionPanelShrinksToNarrowSafeArea() {
        let width = PlayerLayoutMetrics.actionPanelWidth(
            containerWidth: 220,
            safeLeading: 20,
            safeTrailing: 20
        )

        XCTAssertEqual(width, 180)
        XCTAssertLessThanOrEqual(width + 20 + 20, 220)
    }

    func testActionPanelInsetsRespectLandscapeSafeArea() {
        XCTAssertEqual(
            PlayerLayoutMetrics.actionPanelTrailingInset(
                safeTrailing: 44
            ),
            44
        )
        XCTAssertEqual(
            PlayerLayoutMetrics.actionPanelTopInset(safeTop: 47),
            55
        )
    }
}
