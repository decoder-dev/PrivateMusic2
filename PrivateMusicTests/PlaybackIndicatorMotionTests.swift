import XCTest
@testable import PrivateMusic

final class PlaybackIndicatorMotionTests: XCTestCase {
    func testAnimatedBarsStayInsideTheirGlyphAtEveryPhase() {
        for bar in 0..<4 {
            for sample in 0..<1000 {
                let height = PlaybackIndicatorMotion.heightFraction(bar: bar, elapsed: Double(sample) * 0.12,
                                                                    animated: true)
                XCTAssertTrue((0.26...1).contains(height))
            }
        }
    }

    func testReducedMotionBarsDoNotChangeWithTime() {
        for bar in 0..<4 {
            XCTAssertEqual(PlaybackIndicatorMotion.heightFraction(bar: bar, elapsed: 0, animated: false),
                           PlaybackIndicatorMotion.heightFraction(bar: bar, elapsed: 5, animated: false))
        }
    }

    func testInvalidClockCannotCreateInvalidGeometry() {
        for bar in 0..<4 {
            for elapsed in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(PlaybackIndicatorMotion.heightFraction(bar: bar, elapsed: elapsed, animated: true),
                               PlaybackIndicatorMotion.staticHeights[bar])
            }
        }
    }
}
