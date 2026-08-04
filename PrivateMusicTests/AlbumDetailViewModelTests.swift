import XCTest
@testable import PrivateMusic

@MainActor
final class AlbumDetailViewModelTests: XCTestCase {
    // MARK: - isAccessDeniedError classification

    func testVKAccessDeniedCodeIsDetected() {
        let error = APIError.server(
            code: 15,
            message: "Access denied: access to users audio is denied"
        )
        XCTAssertTrue(AlbumDetailViewModel.isAccessDeniedError(error))
    }

    func testOtherVKServerCodesAreNotAccessDenied() {
        for code in [5, 6, 10, 100] {
            let error = APIError.server(code: code, message: "boom")
            XCTAssertFalse(
                AlbumDetailViewModel.isAccessDeniedError(error),
                "VK error code \(code) must not be classified as access denied"
            )
        }
    }

    func testConnectivityErrorsAreNotAccessDenied() {
        XCTAssertFalse(AlbumDetailViewModel.isAccessDeniedError(APIError.offline))
        XCTAssertFalse(AlbumDetailViewModel.isAccessDeniedError(APIError.timedOut))
        XCTAssertFalse(
            AlbumDetailViewModel.isAccessDeniedError(
                APIError.transport("connection reset")
            )
        )
    }

    func testUnauthorizedIsNotAccessDenied() {
        // Unauthorized is handled separately by session recovery, not by
        // the "this album is permanently restricted" messaging.
        XCTAssertFalse(
            AlbumDetailViewModel.isAccessDeniedError(APIError.unauthorized)
        )
    }

    func testNonAPIErrorIsNotAccessDenied() {
        struct SomeOtherError: Error {}
        XCTAssertFalse(
            AlbumDetailViewModel.isAccessDeniedError(SomeOtherError())
        )
    }

    // MARK: - load(force:) wiring

    func testLoadMarksAccessDeniedOnVKCode15() async {
        let model = AlbumDetailViewModel()
        await model.load(force: false) {
            throw APIError.server(
                code: 15,
                message: "Access denied: access to users audio is denied"
            )
        }
        XCTAssertTrue(model.isAccessDenied)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLoadDoesNotMarkAccessDeniedForConnectivityFailure() async {
        let model = AlbumDetailViewModel()
        await model.load(force: false) {
            throw APIError.offline
        }
        XCTAssertFalse(model.isAccessDenied)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSuccessfulLoadClearsAccessDeniedFromAPriorFailure() async {
        let model = AlbumDetailViewModel()
        await model.load(force: false) {
            throw APIError.server(code: 15, message: "denied")
        }
        XCTAssertTrue(model.isAccessDenied)

        await model.load(force: true) {
            MusicPage(items: [], totalCount: 0, nextOffset: nil)
        }
        XCTAssertFalse(model.isAccessDenied)
        XCTAssertNil(model.errorMessage)
    }
}
