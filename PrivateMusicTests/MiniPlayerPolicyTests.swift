import XCTest
@testable import PrivateMusic

final class MiniPlayerProgressPolicyTests: XCTestCase {
    func testProgressIsZeroWhenDurationIsZero() {
        XCTAssertEqual(
            MiniPlayerProgressPolicy.progress(elapsedTime: 12, duration: 0),
            0
        )
    }

    func testProgressIsClampedToUnitRange() {
        XCTAssertEqual(
            MiniPlayerProgressPolicy.progress(elapsedTime: 150, duration: 100),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MiniPlayerProgressPolicy.progress(elapsedTime: 50, duration: 100),
            0.5,
            accuracy: 0.0001
        )
    }

    func testNegativeElapsedTimeDoesNotProduceNegativeProgress() {
        XCTAssertEqual(
            MiniPlayerProgressPolicy.progress(elapsedTime: -8, duration: 100),
            0,
            accuracy: 0.0001
        )
    }
}

final class MiniPlayerGesturePolicyTests: XCTestCase {
    func testSwipeLeftIsNext() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -70, height: 4),
                predictedEndTranslation: CGSize(width: -70, height: 4)
            ),
            .next
        )
    }

    func testSwipeRightIsPrevious() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 70, height: -3),
                predictedEndTranslation: CGSize(width: 70, height: -3)
            ),
            .previous
        )
    }

    func testSwipeUpOpensPlayer() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 2, height: -60),
                predictedEndTranslation: CGSize(width: 2, height: -60)
            ),
            .openPlayer
        )
    }

    func testShortDragProducesNoAction() {
        XCTAssertNil(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 10, height: -8),
                predictedEndTranslation: CGSize(width: 10, height: -8)
            )
        )
    }

    func testVerticalDragIsNotTreatedAsHorizontal() {
        XCTAssertNil(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 40, height: -80),
                predictedEndTranslation: CGSize(width: 40, height: -80),
                verticalThreshold: 100
            )
        )
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 20, height: -80),
                predictedEndTranslation: CGSize(width: 20, height: -80)
            ),
            .openPlayer
        )
    }

    func testFastFlickUsesPredictedEndTranslation() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -20, height: 1),
                predictedEndTranslation: CGSize(width: -90, height: 2)
            ),
            .next
        )
    }

    func testReduceMotionDisablesDecorativeOffset() {
        let offset = MiniPlayerGesturePolicy.dragOffset(
            translation: CGSize(width: 40, height: -30),
            reduceMotion: true
        )
        XCTAssertEqual(offset, .zero)
    }

    func testParallaxOffsetAppliesWhenMotionAllowed() {
        let offset = MiniPlayerGesturePolicy.dragOffset(
            translation: CGSize(width: 50, height: -40),
            reduceMotion: false
        )
        XCTAssertEqual(offset.width, 6, accuracy: 0.001)
        XCTAssertEqual(offset.height, -3.2, accuracy: 0.001)
    }
}
