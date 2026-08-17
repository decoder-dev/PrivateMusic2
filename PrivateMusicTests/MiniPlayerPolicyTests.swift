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

    func testNearDiagonalLeftUpProducesNoAction() {
        XCTAssertNil(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -60, height: -58),
                predictedEndTranslation: CGSize(width: -60, height: -58)
            )
        )
    }

    func testNearDiagonalUpLeftProducesNoAction() {
        XCTAssertNil(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -58, height: -60),
                predictedEndTranslation: CGSize(width: -58, height: -60)
            )
        )
    }

    func testDominantHorizontalLeftIsNext() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -80, height: -30),
                predictedEndTranslation: CGSize(width: -80, height: -30)
            ),
            .next
        )
    }

    func testDominantHorizontalRightIsPrevious() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 80, height: -30),
                predictedEndTranslation: CGSize(width: 80, height: -30)
            ),
            .previous
        )
    }

    func testDominantVerticalUpOpensPlayer() {
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 25, height: -80),
                predictedEndTranslation: CGSize(width: 25, height: -80)
            ),
            .openPlayer
        )
    }

    func testSwipeDownProducesNoAction() {
        XCTAssertNil(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: 4, height: 80),
                predictedEndTranslation: CGSize(width: 4, height: 80)
            )
        )
    }

    func testPredictedTranslationPreservesDominantAxis() {
        // Settled sample is ambiguous / short; predicted is clearly horizontal.
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -22, height: -18),
                predictedEndTranslation: CGSize(width: -90, height: -8)
            ),
            .next
        )
    }

    func testEffectiveTranslationNeverMixesVectorComponents() {
        let translation = CGSize(width: -50, height: -10)
        let predicted = CGSize(width: -10, height: -80)
        let effective = MiniPlayerGesturePolicy.effectiveTranslation(
            translation: translation,
            predictedEndTranslation: predicted
        )
        // Must be exactly one complete vector — never width from one and
        // height from the other (which would invent a false diagonal).
        XCTAssertTrue(
            effective == translation || effective == predicted,
            "effective translation mixed components: \(effective)"
        )
        XCTAssertEqual(effective, predicted)

        // Mixing would invent (-10, -10) or (-50, -80); neither is returned
        // as an action axis here — predicted vertical wins → openPlayer.
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: translation,
                predictedEndTranslation: predicted
            ),
            .openPlayer
        )
        let mixedWouldBeHorizontal = CGSize(
            width: predicted.width,
            height: translation.height
        )
        XCTAssertNotEqual(effective, mixedWouldBeHorizontal)
    }

    func testAxisDominanceRatioBoundaryChoosesVertical() {
        let horizontal: CGFloat = 50
        let vertical =
            horizontal * MiniPlayerGesturePolicy.axisDominanceRatio
        // vertical == horizontal * ratio → vertical branch (`>=`).
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: horizontal, height: -vertical),
                predictedEndTranslation: CGSize(
                    width: horizontal,
                    height: -vertical
                )
            ),
            .openPlayer
        )
    }

    func testAxisDominanceRatioBoundaryChoosesHorizontal() {
        let vertical: CGFloat = 50
        let horizontal =
            vertical * MiniPlayerGesturePolicy.axisDominanceRatio
        // horizontal == vertical * ratio, and vertical check fails first
        // (50 >= 60 * 1.2? no) → horizontal branch (`>=`).
        XCTAssertEqual(
            MiniPlayerGesturePolicy.action(
                translation: CGSize(width: -horizontal, height: -vertical),
                predictedEndTranslation: CGSize(
                    width: -horizontal,
                    height: -vertical
                )
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

final class MiniPlayerAccessoryPolicyTests: XCTestCase {
    func testMissingTrackHidesAccessory() {
        XCTAssertEqual(
            MiniPlayerAccessoryPolicy.presentation(
                hasCurrentTrack: false,
                mode: .expanded
            ),
            .hidden
        )
        XCTAssertEqual(
            MiniPlayerAccessoryPolicy.presentation(
                hasCurrentTrack: false,
                mode: .inline
            ),
            .hidden
        )
    }

    func testExpandedShowsMetadataNextProgressAndGlass() {
        XCTAssertEqual(
            MiniPlayerAccessoryPolicy.presentation(
                hasCurrentTrack: true,
                mode: .expanded
            ),
            .expanded
        )
        XCTAssertTrue(MiniPlayerAccessoryPolicy.showsArtist(.expanded))
        XCTAssertTrue(MiniPlayerAccessoryPolicy.showsNextButton(.expanded))
        XCTAssertTrue(MiniPlayerAccessoryPolicy.showsPreviousButton(.expanded))
        XCTAssertTrue(MiniPlayerAccessoryPolicy.showsProgress(.expanded))
        XCTAssertFalse(MiniPlayerAccessoryPolicy.showsOwnGlassChrome(.expanded))
    }

    func testInlineShowsMinimalChrome() {
        XCTAssertEqual(
            MiniPlayerAccessoryPolicy.presentation(
                hasCurrentTrack: true,
                mode: .inline
            ),
            .inline
        )
        XCTAssertFalse(MiniPlayerAccessoryPolicy.showsArtist(.inline))
        XCTAssertFalse(MiniPlayerAccessoryPolicy.showsNextButton(.inline))
        XCTAssertTrue(MiniPlayerAccessoryPolicy.showsPreviousButton(.inline))
        XCTAssertFalse(MiniPlayerAccessoryPolicy.showsProgress(.inline))
        XCTAssertFalse(MiniPlayerAccessoryPolicy.showsOwnGlassChrome(.inline))
    }

    func testBufferingReplacesPlayPauseIndicator() {
        XCTAssertTrue(
            MiniPlayerAccessoryPolicy.showsBufferingIndicator(isBuffering: true)
        )
        XCTAssertFalse(
            MiniPlayerAccessoryPolicy.showsBufferingIndicator(isBuffering: false)
        )
    }

    /// The progress line used to run along the container's bottom edge,
    /// where the border stroke and the corner curve both cross it — on the
    /// legacy dock it read as a stray blue line overlapping the card.
    func testProgressLineClearsTheContainerBorder() {
        XCTAssertGreaterThanOrEqual(
            MiniPlayerLayoutMetrics.progressSideInset,
            MiniPlayerLayoutMetrics.cornerRadius,
            "progress line must start past the rounded corner"
        )
        XCTAssertGreaterThan(
            MiniPlayerLayoutMetrics.progressBottomInset,
            0,
            "progress line must not sit on the border stroke"
        )
    }

    /// Insetting it is only acceptable if the dock does not grow: testers
    /// already flagged the floating dock as sitting too high.
    func testProgressInsetDoesNotRaiseTheDock() {
        let contentHeight =
            MiniPlayerLayoutMetrics.verticalPadding
            + MiniPlayerLayoutMetrics.artworkSize
            + MiniPlayerLayoutMetrics.progressTopSpacing
            + MiniPlayerLayoutMetrics.progressHeight
            + MiniPlayerLayoutMetrics.progressBottomInset

        XCTAssertEqual(contentHeight, 58)
        XCTAssertGreaterThanOrEqual(
            contentHeight,
            MiniPlayerLayoutMetrics.minHeight
        )
    }
}
