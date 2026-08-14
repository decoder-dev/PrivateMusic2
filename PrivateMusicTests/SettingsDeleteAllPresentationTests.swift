import XCTest
@testable import PrivateMusic

final class SettingsDeleteAllPresentationTests: XCTestCase {
    private let bytes: (Int64) -> String = { value in
        "\(value) bytes"
    }

    func testEmptyIdleShowsDoneStatusAndIsDisabled() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .idle,
            hasContent: false,
            downloadedTrackCount: 0,
            totalBytes: 0,
            formattedBytes: bytes
        )

        XCTAssertEqual(presentation.title, L10n.text("all_saved_files_have_been_removed"))
        XCTAssertEqual(presentation.subtitle, L10n.text("done"))
        XCTAssertEqual(presentation.systemImage, "checkmark.circle.fill")
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertFalse(presentation.showsProgress)
    }

    func testIdleWithContentShowsActiveDeleteRow() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .idle,
            hasContent: true,
            downloadedTrackCount: 3,
            totalBytes: 25_000_000,
            formattedBytes: bytes
        )

        XCTAssertEqual(presentation.title, L10n.text("remove_all_saved_files"))
        XCTAssertEqual(presentation.systemImage, "trash")
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertTrue(presentation.subtitle.contains("3"))
        XCTAssertTrue(presentation.subtitle.contains("25000000 bytes"))
    }

    func testDeletingShowsSpinnerAndDisablesRow() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .deleting,
            hasContent: true,
            downloadedTrackCount: 3,
            totalBytes: 25_000_000,
            formattedBytes: bytes
        )

        XCTAssertEqual(
            presentation.title,
            L10n.text("removing_saved_files")
        )
        XCTAssertTrue(presentation.showsProgress)
        XCTAssertFalse(presentation.isEnabled)
    }

    func testCompletedShowsCheckmarkStatus() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .completed,
            hasContent: false,
            downloadedTrackCount: 0,
            totalBytes: 0,
            formattedBytes: bytes
        )

        XCTAssertEqual(presentation.title, L10n.text("all_saved_files_have_been_removed"))
        XCTAssertEqual(presentation.subtitle, L10n.text("done"))
        XCTAssertEqual(presentation.systemImage, "checkmark.circle.fill")
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertFalse(presentation.showsProgress)
    }

    func testIncompleteShowsRemainingAndIsRetryEnabled() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .incomplete(remainingBytes: 8_000_000, remainingItems: 2),
            hasContent: true,
            downloadedTrackCount: 2,
            totalBytes: 8_000_000,
            formattedBytes: bytes
        )

        XCTAssertEqual(presentation.title, L10n.text("some_files_could_not_be_removed"))
        XCTAssertEqual(presentation.systemImage, "exclamationmark.triangle.fill")
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertTrue(presentation.subtitle.contains("2"))
        XCTAssertTrue(presentation.subtitle.contains("8000000 bytes"))
    }

    func testNewContentAfterCompletedResetsToActiveIdle() {
        let presentation = OfflineDeleteAllPresentation.resolve(
            phase: .completed,
            hasContent: true,
            downloadedTrackCount: 1,
            totalBytes: 4_000_000,
            formattedBytes: bytes
        )

        XCTAssertEqual(presentation.title, L10n.text("remove_all_saved_files"))
        XCTAssertEqual(presentation.systemImage, "trash")
        XCTAssertTrue(presentation.isEnabled)
    }

    func testControlExistsForEveryPhase() {
        let phases: [OfflineDeleteAllPhase] = [
            .idle,
            .deleting,
            .completed,
            .incomplete(remainingBytes: 1, remainingItems: 1),
        ]
        for phase in phases {
            for hasContent in [false, true] {
                let presentation = OfflineDeleteAllPresentation.resolve(
                    phase: phase,
                    hasContent: hasContent,
                    downloadedTrackCount: hasContent ? 1 : 0,
                    totalBytes: hasContent ? 1 : 0,
                    formattedBytes: bytes
                )
                XCTAssertFalse(presentation.title.isEmpty)
                XCTAssertFalse(presentation.subtitle.isEmpty)
                XCTAssertFalse(presentation.systemImage.isEmpty)
            }
        }
    }
}
