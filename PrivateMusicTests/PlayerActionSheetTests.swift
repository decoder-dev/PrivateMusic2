import XCTest
@testable import PrivateMusic

final class PlayerActionSheetTests: XCTestCase {
    func testActionSheetFitsSmallSupportedPhoneHeight() {
        XCTAssertGreaterThan(
            PlayerActionSheetMetrics.preferredHeight,
            400
        )
        XCTAssertLessThanOrEqual(
            PlayerActionSheetMetrics.preferredHeight,
            520
        )
    }

    func testActionSheetUsesAccessibleMinimumTapTargets() {
        XCTAssertGreaterThanOrEqual(
            PlayerActionSheetMetrics.minimumTapTarget,
            44
        )
    }

    func testAllSessionActionsAreEnabledWhenIdle() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: false
        )

        XCTAssertTrue(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
    }

    func testLibraryMutationDisablesOnlyLibraryAction() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: true
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertTrue(state.showsLibraryProgress)
    }

    func testMetadataShareRemainsAvailableWithoutCredentials() {
        let state = PlayerActionAvailability(
            hasSession: false,
            isUpdatingLibrary: false
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertFalse(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
    }
}

final class PlayerContentLayoutTests: XCTestCase {
    func testCompactPhoneReservesBottomDockWithoutOverflow() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .compact)
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 667)
        XCTAssertGreaterThan(metrics.artworkSize, 0)
        XCTAssertLessThanOrEqual(
            metrics.artworkSize,
            metrics.contentWidth
        )
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 667),
            657
        )
        XCTAssertEqual(metrics.quickActionsHeight, 64)
    }

    func testStandardPhonePinsDockAboveHomeIndicator() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 844),
            safeBottom: 34,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .standard)
        XCTAssertEqual(metrics.bottomPadding, 34)
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 844),
            810
        )
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 844)
    }

    func testTallPhoneUsesAvailableArtworkSpace() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 430, height: 932),
            safeBottom: 34,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .tall)
        XCTAssertGreaterThan(metrics.artworkSize, 300)
        XCTAssertLessThanOrEqual(
            metrics.artworkSize,
            metrics.contentWidth
        )
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 932)
    }

    func testLandscapeUsesTwoColumnsAndNotchInsets() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 844, height: 390),
            safeBottom: 21,
            safeLeading: 47,
            safeTrailing: 47,
            hasAlbum: true
        )

        XCTAssertEqual(metrics.mode, .landscape)
        XCTAssertGreaterThanOrEqual(metrics.leadingPadding, 55)
        XCTAssertGreaterThanOrEqual(metrics.trailingPadding, 55)
        XCTAssertGreaterThan(metrics.landscapeColumnSpacing, 0)
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 390)
        XCTAssertEqual(
            metrics.quickActionsBottomY(containerHeight: 390),
            369
        )
    }

    func testLongerMetadataReducesArtworkInsteadOfDockSpace() {
        let withAlbum = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )
        let withoutAlbum = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: false
        )

        XCTAssertLessThanOrEqual(
            withAlbum.artworkSize,
            withoutAlbum.artworkSize
        )
        XCTAssertEqual(
            withAlbum.quickActionsHeight,
            withoutAlbum.quickActionsHeight
        )
        XCTAssertEqual(
            withAlbum.bottomPadding,
            withoutAlbum.bottomPadding
        )
    }

    func testAccessibilityTextStillFitsCompactPhone() {
        let normal = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            hasAlbum: true
        )
        let accessible = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 375, height: 667),
            usesAccessibilityText: true,
            hasAlbum: true
        )

        XCTAssertTrue(accessible.usesAccessibilityText)
        XCTAssertEqual(accessible.quickActionsHeight, 72)
        XCTAssertLessThanOrEqual(
            accessible.minimumContentHeight,
            667
        )
        XCTAssertLessThanOrEqual(
            accessible.artworkSize,
            normal.artworkSize
        )
        XCTAssertEqual(
            accessible.quickActionsBottomY(containerHeight: 667),
            normal.quickActionsBottomY(containerHeight: 667)
        )
    }

    func testPortraitMetricsRemainContinuousAcrossModeThresholds() {
        let compactEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 719)
        )
        let standardEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 720)
        )
        let standardTallEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 859)
        )
        let tallEdge = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: 860)
        )

        XCTAssertEqual(compactEdge.mode, .compact)
        XCTAssertEqual(standardEdge.mode, .standard)
        XCTAssertEqual(standardTallEdge.mode, .standard)
        XCTAssertEqual(tallEdge.mode, .tall)
        XCTAssertLessThan(
            abs(compactEdge.artworkSize - standardEdge.artworkSize),
            3
        )
        XCTAssertLessThan(
            abs(
                standardTallEdge.artworkSize
                    - tallEdge.artworkSize
            ),
            3
        )
        XCTAssertLessThan(
            abs(
                compactEdge.artworkTopSpacing
                    - standardEdge.artworkTopSpacing
            ),
            1
        )
        XCTAssertLessThan(
            abs(
                standardTallEdge.artworkTopSpacing
                    - tallEdge.artworkTopSpacing
            ),
            1
        )
    }
}
