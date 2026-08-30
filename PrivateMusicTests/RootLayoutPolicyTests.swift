import SwiftUI
import XCTest
@testable import PrivateMusic

final class RootLayoutPolicyTests: XCTestCase {
    /// The bug a tester hit: on a Pro Max, landscape reports regular width,
    /// so the root swapped from tabs to the iPad sidebar. Because the two
    /// are different views, everything under them — including the pushed
    /// Explore screen — was rebuilt from scratch and lost.
    func testAPhoneKeepsTabsWhicheverWayItIsTurned() {
        XCTAssertFalse(
            RootLayoutPolicy.usesSidebar(
                isPad: false,
                horizontalSizeClass: .compact
            ),
            "portrait"
        )
        XCTAssertFalse(
            RootLayoutPolicy.usesSidebar(
                isPad: false,
                horizontalSizeClass: .regular
            ),
            "landscape on a Plus or Pro Max"
        )
    }

    func testAnIPadGetsTheSidebar() {
        XCTAssertTrue(
            RootLayoutPolicy.usesSidebar(
                isPad: true,
                horizontalSizeClass: .regular
            )
        )
    }

    /// Slide Over and a narrow split are the cases the size class still has
    /// to decide: an iPad that narrow wants tabs, not a sidebar.
    func testANarrowIPadKeepsTabs() {
        XCTAssertFalse(
            RootLayoutPolicy.usesSidebar(
                isPad: true,
                horizontalSizeClass: .compact
            )
        )
    }

    /// The size class is optional and is briefly absent while a scene is
    /// being set up. Answering "sidebar" then would flip the container a
    /// moment after launch, which is the very thing this avoids.
    func testAnUnknownSizeClassDoesNotGetTheSidebar() {
        XCTAssertFalse(
            RootLayoutPolicy.usesSidebar(isPad: true, horizontalSizeClass: nil)
        )
        XCTAssertFalse(
            RootLayoutPolicy.usesSidebar(isPad: false, horizontalSizeClass: nil)
        )
    }
}
