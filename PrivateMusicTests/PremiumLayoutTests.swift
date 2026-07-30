import XCTest
@testable import PrivateMusic

final class PremiumLayoutTests: XCTestCase {
    func testRadiusScaleKeepsControlsBelowCards() {
        XCTAssertLessThan(PremiumLayout.controlRadius, PremiumLayout.compactRadius)
        XCTAssertLessThan(PremiumLayout.compactRadius, PremiumLayout.cardRadius)
    }

    func testArtworkRadiusHasReadableMinimumAndCardMaximum() {
        XCTAssertEqual(PremiumLayout.artworkRadius(for: 20), 8)
        XCTAssertEqual(
            PremiumLayout.artworkRadius(for: 1_000),
            PremiumLayout.cardRadius
        )
    }

    func testArtworkRadiusScalesBetweenBounds() {
        let compact = PremiumLayout.artworkRadius(for: 46)
        let large = PremiumLayout.artworkRadius(for: 100)

        XCTAssertGreaterThanOrEqual(compact, 8)
        XCTAssertGreaterThan(large, compact)
        XCTAssertLessThanOrEqual(large, PremiumLayout.cardRadius)
    }
}
