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
            isUpdatingLibrary: false,
            isPreparingShare: false
        )

        XCTAssertTrue(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
    }

    func testLibraryMutationDisablesOnlyLibraryAction() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: true,
            isPreparingShare: false
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertTrue(state.canShare)
        XCTAssertTrue(state.showsLibraryProgress)
    }

    func testSharePreparationDisablesOnlyShareAction() {
        let state = PlayerActionAvailability(
            hasSession: true,
            isUpdatingLibrary: false,
            isPreparingShare: true
        )

        XCTAssertTrue(state.canModifyLibrary)
        XCTAssertTrue(state.canAddToPlaylist)
        XCTAssertFalse(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
    }

    func testSessionActionsAreDisabledWithoutCredentials() {
        let state = PlayerActionAvailability(
            hasSession: false,
            isUpdatingLibrary: false,
            isPreparingShare: false
        )

        XCTAssertFalse(state.canModifyLibrary)
        XCTAssertFalse(state.canAddToPlaylist)
        XCTAssertFalse(state.canShare)
        XCTAssertFalse(state.showsLibraryProgress)
    }
}
