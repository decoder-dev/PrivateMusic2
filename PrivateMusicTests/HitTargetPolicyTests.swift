import XCTest
@testable import PrivateMusic

final class HitTargetPolicyTests: XCTestCase {
    /// The whole point: a control drawn smaller than the HIG minimum ends
    /// up accepting touches across the full 44 points.
    func testOutsetBringsSmallControlsUpToTheMinimum() {
        for visualSize in [22.0, 24.0, 30.0, 32.0, 34.0] as [CGFloat] {
            let reach = visualSize
                + HitTargetPolicy.outset(forVisualSize: visualSize) * 2
            XCTAssertEqual(
                reach,
                HitTargetPolicy.minimum,
                accuracy: 0.001,
                "a \(visualSize)pt control must still answer 44pt of finger"
            )
        }
    }

    /// A control that is already big enough must not have its touch area
    /// pulled *in* — a negative outset would shrink the hit region.
    func testControlsAtOrOverTheMinimumAreLeftAlone() {
        XCTAssertEqual(HitTargetPolicy.outset(forVisualSize: 44), 0)
        XCTAssertEqual(HitTargetPolicy.outset(forVisualSize: 58), 0)
        XCTAssertEqual(HitTargetPolicy.outset(forVisualSize: 120), 0)
    }

    /// 44×44 is the figure the Human Interface Guidelines name, and the
    /// design system already carried it — the two must not drift apart.
    func testMinimumMatchesTheDesignSystemToken() {
        XCTAssertEqual(HitTargetPolicy.minimum, 44)
        XCTAssertEqual(HitTargetPolicy.minimum, PremiumLayout.minimumTapTarget)
        XCTAssertEqual(HitTargetPolicy.minimum, BubbleMetrics.minimumTapTarget)
    }
}
